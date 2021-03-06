%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

-module(capi_replication).

-export([get_missing_revs/2, update_replicated_docs/3]).

-include("couch_db.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

get_missing_revs(#db{name = BucketBin,
                     filepath = undefined}, JsonDocIdRevs) ->
    Bucket = binary_to_list(BucketBin),

    Results =
        lists:foldr(
          fun ({Id, Rev}, Acc) ->
                  {VBucket, _Node} = cb_util:vbucket_from_id(Bucket, Id),

                  case is_missing_rev(Bucket, VBucket, Id, Rev) of
                      false ->
                          Acc;
                      true ->
                          [{Id, Rev} | Acc]
                  end;
              (_, _) ->
                  throw(unsupported)
          end, [], JsonDocIdRevs),
    {ok, Results};
get_missing_revs(#db{name = DbName}, JsonDocIdRevs) ->
    {Bucket, VBucket} = capi_utils:split_dbname(DbName),

    Results =
        lists:foldr(
          fun ({Id, Rev}, Acc) ->
                  case is_missing_rev(Bucket, VBucket, Id, Rev) of
                      false ->
                          Acc;
                      true ->
                          [{Id, Rev} | Acc]
                  end;
              (_, _) ->
                  throw(unsupported)
          end, [], JsonDocIdRevs),
    {ok, Results}.

is_missing_rev(Bucket, VBucket, Id, Rev) ->
    case capi_utils:get_meta(Bucket, VBucket, Id) of
        {error, enoent, _CAS} ->
            true;
        {error, not_my_vbucket} ->
            throw({bad_request, not_my_vbucket});
        {ok, OurRev, _Deleted, _Props} ->
            %% we do not have any information about deletedness of
            %% the remote side thus we use only revisions to
            %% determine a winner
            case winner(Rev, OurRev) of
                ours ->
                    false;
                theirs ->
                    true
            end
    end.

%% In case of one or more errors, just return the first one. Otherwise,
%% return ok. Also notice that in case of error, we return {ok, Error}. This is
%% per the Couch's update_docs() semantics.
make_return_tuple({ok, Errors}) ->
    case Errors of
        [] ->
            ok;
        [Error | _] ->
            {ok, Error}
    end.

update_replicated_docs(#db{name = BucketBin,
                           filepath = undefined},
                       Docs, Options) ->
    Bucket = binary_to_list(BucketBin),

    case proplists:get_value(all_or_nothing, Options, false) of
        true ->
            throw(unsupported);
        false ->
            ok
    end,

    Errors =
        lists:foldr(
          fun (#doc{id = Id, rev = Rev} = Doc, ErrorsAcc) ->
                  {VBucket, _Node} = cb_util:vbucket_from_id(Bucket, Id),

                  case do_update_replicated_doc(Bucket, VBucket, Doc) of
                      ok ->
                          ErrorsAcc;
                      {error, Error} ->
                          [{{Id, Rev}, Error} | ErrorsAcc]
                  end
          end,
          [], Docs),

    make_return_tuple({ok, Errors});
update_replicated_docs(#db{name = DbName}, Docs, Options) ->
    {Bucket, VBucket} = capi_utils:split_dbname(DbName),

    case proplists:get_value(all_or_nothing, Options, false) of
        true ->
            throw(unsupported);
        false ->
            ok
    end,

    Errors =
        lists:foldr(
          fun (#doc{id = Id, rev = Rev} = Doc, ErrorsAcc) ->
                  case do_update_replicated_doc(Bucket, VBucket, Doc) of
                      ok ->
                          ErrorsAcc;
                      {error, Error} ->
                          [{{Id, Rev}, Error} | ErrorsAcc]
                  end
          end,
          [], Docs),

    make_return_tuple({ok, Errors}).

update_replicated_doc(#db{name = BucketBin,
                          filepath = undefined},
                      #doc{id = Id} = Doc,
                      _Options) ->
    Bucket = binary_to_list(BucketBin),
    {VBucket, _Node} = cb_util:vbucket_from_id(Bucket, Id),

    case do_update_replicated_doc(Bucket, VBucket, Doc) of
        ok ->
            ok;
        {error, Error} ->
            throw(Error)
    end;
update_replicated_doc(#db{name = DbName},
                      #doc{} = Doc,
                      _Options)->
    {Bucket, VBucket} = capi_utils:split_dbname(DbName),

    case do_update_replicated_doc(Bucket, VBucket, Doc) of
        ok ->
            ok;
        {error, Error} ->
            throw(Error)
    end.

winner({_SeqNo1, _RevId1} = Theirs,
       {_SeqNo2, _RevId2} = Ours) ->
    winner_helper(Theirs, Ours);
winner({_SeqNo1, _NotDeleted1, _RevId1} = Theirs,
       {_SeqNo2, _NotDeleted2, _RevId3} = Ours) ->
    winner_helper(Theirs, Ours).

winner_helper(Theirs, Ours) ->
    %% Ours can be equal to Theirs; in this case we prefer our revision to
    %% avoid excessive work
    case max(Theirs, Ours) of
        Ours ->
            ours;
        Theirs ->
            theirs
    end.

do_update_replicated_doc(_Bucket, _VBucket,
                         #doc{id = <<?LOCAL_DOC_PREFIX, _/binary>>}) ->
    ok;
do_update_replicated_doc(Bucket, VBucket,
                         #doc{id = Id, rev = Rev,
                              body = Value0, deleted = Deleted} = _Doc) ->
    case Value0 of
    {_} ->
        Value = ?JSON_ENCODE(filter_out_mccouch_fields(Value0));
    _ ->
        Value = Value0
    end,
    do_update_replicated_doc_loop(Bucket, VBucket, Id, Rev, Value, Deleted).

do_update_replicated_doc_loop(Bucket, VBucket, DocId,
                              {DocSeqNo, DocRevId} = DocRev,
                              DocValue, DocDeleted) ->
    RV =
        case capi_utils:get_meta(Bucket, VBucket, DocId) of
            {error, enoent, CAS} ->
                case DocDeleted of
                    true ->
                        do_delete_with_meta(Bucket, DocId, VBucket, DocRev,
                                            CAS);
                    false ->
                        do_set_with_meta(Bucket, DocId, VBucket, DocValue,
                                         DocRev, CAS)
                end;
            {error, not_my_vbucket} ->
                {error, {bad_request, not_my_vbucket}};
            {ok, {OurSeqNo, OurRevId}, Deleted, Props} ->
                DocRevExt = {DocSeqNo, not(DocDeleted), DocRevId},
                OurRevExt = {OurSeqNo, not(Deleted), OurRevId},

                case winner(DocRevExt, OurRevExt) of
                    ours ->
                        ok;
                    theirs ->
                        {cas, CAS} = lists:keyfind(cas, 1, Props),
                        case DocDeleted of
                            true ->
                                do_delete_with_meta(Bucket, DocId, VBucket,
                                                    DocRev, CAS);
                            false ->
                                do_set_with_meta(Bucket, DocId, VBucket,
                                                 DocValue, DocRev, CAS)
                        end
                end
        end,

    case RV of
        retry ->
            do_update_replicated_doc_loop(Bucket, VBucket, DocId,
                                          DocRev, DocValue, DocDeleted);
        _Other ->
            RV
    end.

do_set_with_meta(Bucket, DocId, VBucket, DocValue, DocRev, CAS) ->
    case ns_memcached:set_with_meta(Bucket, DocId,
                                    VBucket, DocValue,
                                    {revid, DocRev}, CAS) of
        {ok, _, _} ->
            ok;
        {memcached_error, key_enoent, _} ->
            retry;
        {memcached_error, key_eexists, _} ->
            retry;
        {memcached_error, not_my_vbucket, _} ->
            {error, {bad_request, not_my_vbucket}};
        {memcached_error, einval, _} ->
            {error, {bad_request, einval}}
    end.

do_delete_with_meta(Bucket, DocId, VBucket, DocRev, CAS) ->
    case ns_memcached:delete_with_meta(Bucket, DocId, VBucket, {revid, DocRev},
                                       CAS) of
        {ok, _, _} ->
            ok;
        {memcached_error, key_enoent, _} ->
            retry;
        {memcached_error, not_my_vbucket, _} ->
            {error, {bad_request, not_my_vbucket}};
        {memcached_error, einval, _} ->
            {error, {bad_request, einval}}
    end.

filter_out_mccouch_fields({Props}) ->
    FilteredProps = lists:filter(
                      fun ({<<$$, _/binary>>, _Value}) ->
                              false;
                          ({_, _}) ->
                              true
                      end, Props),
    {FilteredProps}.
