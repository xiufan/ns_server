%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% Monitor and maintain the vbucket layout of each bucket.
%% There is one of these per bucket.
%%
%% @doc Rebalancing functions.
%%

-module(ns_rebalancer).

-include("ns_common.hrl").
-include("ns_stats.hrl").

-export([failover/1,
         generate_initial_map/1,
         rebalance/3,
         unbalanced/2,
         buckets_replication_statuses/0]).


-define(DATA_LOST, 1).
-define(BAD_REPLICATORS, 2).


%%
%% API
%%

%% @doc Fail a node. Doesn't eject the node from the cluster. Takes
%% effect immediately.
failover(Node) ->
    lists:foreach(fun (Bucket) -> failover(Bucket, Node) end,
                  ns_bucket:get_bucket_names()).

-spec failover(string(), atom()) -> ok.
failover(Bucket, Node) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    Servers = proplists:get_value(servers, BucketConfig),
    case proplists:get_value(type, BucketConfig) of
        membase ->
            %% Promote replicas of vbuckets on this node
            Map = proplists:get_value(map, BucketConfig),
            Map1 = mb_map:promote_replicas(Map, [Node]),
            case Map1 of
                undefined ->
                    ok;
                _ ->
                    case [I || {I, [undefined|_]} <- misc:enumerate(Map1, 0)] of
                        [] -> ok; % Phew!
                        MissingVBuckets ->
                            ?rebalance_error("Lost data in ~p for ~w", [Bucket, MissingVBuckets]),
                            ?user_log(?DATA_LOST,
                                      "Data has been lost for ~B% of vbuckets in bucket ~p.",
                                      [length(MissingVBuckets) * 100 div length(Map), Bucket])
                    end
            end,
            ns_bucket:set_fast_forward_map(Bucket, undefined),
            case Map1 of
                undefined ->
                    undefined = Map;            % Do nothing. Map didn't change
                _ ->
                    ns_bucket:set_map(Bucket, Map1)
            end,
            ns_bucket:set_servers(Bucket, lists:delete(Node, Servers)),
            try
                ns_janitor:cleanup(Bucket, [])
            catch
                E:R ->
                    ?rebalance_error("Janitor cleanup of ~p failed after failover of ~p: ~p",
                                     [Bucket, Node, {E, R}])
            end;
        memcached ->
            ns_bucket:set_servers(Bucket, lists:delete(Node, Servers))
    end.

generate_vbucket_map(CurrentMap, KeepNodes, BucketConfig) ->
    Opts = [{maps_history, ns_bucket:past_vbucket_maps()} | ns_bucket:config_to_map_options(BucketConfig)],
    {mb_map:generate_map(CurrentMap, KeepNodes, Opts), Opts}.

generate_initial_map(BucketConfig) ->
    Chain = lists:duplicate(proplists:get_value(num_replicas, BucketConfig) + 1,
                            undefined),
    Map1 = lists:duplicate(proplists:get_value(num_vbuckets, BucketConfig),
                          Chain),
    Servers = proplists:get_value(servers, BucketConfig),
    {MapRV, _} = generate_vbucket_map(Map1, Servers, BucketConfig),
    MapRV.


rebalance(KeepNodes, EjectNodes, FailedNodes) ->
    LiveNodes = KeepNodes ++ EjectNodes,
    AllNodes = LiveNodes ++ FailedNodes,
    DeactivateNodes = EjectNodes ++ FailedNodes,
    BucketConfigs = ns_bucket:get_buckets(),
    NumBuckets = length(BucketConfigs),
    ?rebalance_debug("BucketConfigs = ~p", [BucketConfigs]),
    EarlyEject = FailedNodes -- [node()],
    try
        %% Eject failed nodes first so they don't cause trouble
        eject_nodes(EarlyEject),
        lists:foreach(fun ({I, {BucketName, BucketConfig}}) ->
                              ?rebalance_info("Rebalancing bucket ~p with config ~p",
                                              [BucketName, BucketConfig]),
                              BucketCompletion = I / NumBuckets,
                              ns_orchestrator:update_progress(
                                dict:from_list([{N, BucketCompletion}
                                                || N <- AllNodes])),
                              case proplists:get_value(type, BucketConfig) of
                                  memcached ->
                                      ns_bucket:set_servers(BucketName, KeepNodes);
                                  membase ->
                                      %% Only start one bucket at a time to avoid
                                      %% overloading things
                                      ns_bucket:set_servers(BucketName, LiveNodes),
                                      wait_for_memcached(LiveNodes, BucketName, 10),
                                      ns_janitor:cleanup(BucketName, [{timeout, 1}]),
                                      {ok, NewConf} =
                                          ns_bucket:get_bucket(BucketName),
                                      NewMap =
                                          rebalance(BucketName, NewConf,
                                                    KeepNodes, BucketCompletion,
                                                    NumBuckets),
                                      verify_replication(BucketName, LiveNodes,
                                                         NewMap)
                              end
                      end, misc:enumerate(BucketConfigs, 0))
    catch
        E:R ->
            %% Eject this node since the orchestrator can still be running on a
            %% failed node (should be fixed)
            case lists:member(node(), FailedNodes) of
                true ->
                    %% Push out the config before we shoot ourselves
                    %% in the head.
                    ns_config_rep:push(),
                    eject_nodes([node()]);
                false ->
                    ok
            end,
            erlang:raise(E, R, erlang:get_stacktrace())
    end,
    ns_config:sync_announcements(),
    ns_config_rep:synchronize(),
    eject_nodes(DeactivateNodes -- EarlyEject).



%% @doc Rebalance the cluster. Operates on a single bucket. Will
%% either return ok or exit with reason 'stopped' or whatever reason
%% was given by whatever failed.
rebalance(Bucket, Config, KeepNodes, BucketCompletion, NumBuckets) ->
    Map = proplists:get_value(map, Config),
    {FastForwardMap, MapOptions} = generate_vbucket_map(Map, KeepNodes, Config),
    ?rebalance_info("Target map (distance: ~p):~n~p", [(catch mb_map:vbucket_movements(Map, FastForwardMap)), FastForwardMap]),
    ns_bucket:update_vbucket_map_history(FastForwardMap, MapOptions),
    ns_bucket:set_fast_forward_map(Bucket, FastForwardMap),
    ProgressFun =
        fun (P) ->
                Progress = dict:map(fun (_, N) ->
                                            N / NumBuckets + BucketCompletion
                                    end, P),
                ns_orchestrator:update_progress(Progress)
        end,
    {ok, Pid} =
        ns_vbucket_mover:start_link(Bucket, Map, FastForwardMap, ProgressFun),
    case wait_for_mover(Pid) of
        ok ->
            ns_bucket:set_fast_forward_map(Bucket, undefined),
            ns_bucket:set_servers(Bucket, KeepNodes),
            FastForwardMap;
        stopped ->
            exit(stopped)
    end.


%% @doc Determine if a particular bucket is unbalanced. Returns true
%% iff the max vbucket count in any class on any server is >2 more
%% than the min.
-spec unbalanced(map(), [atom()]) -> boolean().
unbalanced(Map, Servers) ->
    lists:any(fun (Histogram) ->
                      case [N || {_, N} <- Histogram] of
                          [] -> false;
                          Counts -> lists:max(Counts) - lists:min(Counts) > 2
                      end
              end, histograms(Map, Servers)).


%%
%% Internal functions
%%

%% @private


%% @doc Eject a list of nodes from the cluster, making sure this node is last.
eject_nodes(Nodes) ->
    %% Leave myself last
    LeaveNodes = case lists:member(node(), Nodes) of
                     true ->
                         (Nodes -- [node()]) ++ [node()];
                     false ->
                         Nodes
                 end,
    lists:foreach(fun (N) ->
                          ns_cluster_membership:deactivate([N]),
                          ns_cluster:leave(N)
                  end, LeaveNodes).


%% for each replication turn in Map returns list of pairs {node(),
%% integer()} representing histogram of occurences of nodes in this
%% replication turn. Missing Servers are represented with counts of 0.
%% Nodes that are not present in Servers are ignored.
histograms(Map, Servers) ->
    Histograms = [lists:keydelete(
                    undefined, 1,
                    misc:uniqc(
                      lists:sort(
                        [N || N<-L,
                              lists:member(N, Servers)]))) ||
                     L <- misc:rotate(Map)],
    lists:map(fun (H) ->
                      Missing = [{N, 0} || N <- Servers,
                                           not lists:keymember(N, 1, H)],
                      Missing ++ H
              end, Histograms).



verify_replication(Bucket, Nodes, Map) ->
    ExpectedReplicators =
        lists:sort(
          lists:flatmap(
            fun ({V, Chain}) ->
                    [{Src, Dst, V} || {Src, Dst} <- misc:pairs(Chain), Src =/= undefined, Dst =/= undefined]
            end, misc:enumerate(Map, 0))),
    ActualReplicators = cb_replication:replicas(Bucket, Nodes),

    case misc:comm(ExpectedReplicators, ActualReplicators) of
        {[], [], _} ->
            ok;
        {Missing, Extra, _} ->
            ?user_log(?BAD_REPLICATORS,
                      "Bad replicators after rebalance:~nMissing = ~p~nExtras = ~p",
                      [Missing, Extra]),
            exit(bad_replicas)
    end.


%% @doc Wait until either all memcacheds are up or stop is pressed.
wait_for_memcached(Nodes, Bucket, -1) ->
    exit({wait_for_memcached_failed, Bucket, Nodes});
wait_for_memcached(Nodes, Bucket, Tries) ->
    case [Node || Node <- Nodes, not ns_memcached:connected(Node, Bucket)] of
        [] ->
            ok;
        Down ->
            receive
                stop ->
                    exit(stopped)
            after 1000 ->
                    ?rebalance_info("Waiting for ~p", [Down]),
                    wait_for_memcached(Down, Bucket, Tries-1)
            end
    end.


-spec wait_for_mover(pid()) -> ok | stopped.
wait_for_mover(Pid) ->
    Ref = erlang:monitor(process, Pid),
    wait_for_mover_tail(Pid, Ref).

wait_for_mover_tail(Pid, Ref) ->
    receive
        stop ->
            erlang:unlink(Pid),
            (catch Pid ! {'EXIT', self(), shutdown}),
            wait_for_mover_tail(Pid, Ref);
        {'DOWN', Ref, _, _, Reason} ->
            case Reason of
                %% monitoring was too late, but because we're linked
                %% and don't trap exits the fact that we're alife
                %% means it went normal
                noproc ->
                    ok;
                normal ->
                    ok;
                shutdown ->
                    stopped;
                _ ->
                    exit({mover_crashed, Reason})
            end
    end.

%% NOTE: this is rpc:multicall-ed by 1.8 nodes.
buckets_replication_statuses() ->
    Buckets = ns_bucket:get_bucket_names(),
    failover_safeness_level:buckets_replication_statuses_compat(Buckets).
