%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_exchange_type_topic).

-include("rabbit.hrl").

-behaviour(rabbit_exchange_type).

-export([description/0, route/2]).
-export([validate/1, create/2, recover/2, delete/3, add_binding/3,
         remove_bindings/3, assert_args_equivalence/2]).
-include("rabbit_exchange_type_spec.hrl").

-rabbit_boot_step({?MODULE,
                   [{description, "exchange type topic"},
                    {mfa,         {rabbit_registry, register,
                                   [exchange, <<"topic">>, ?MODULE]}},
                    {requires,    rabbit_registry},
                    {enables,     kernel_ready}]}).

%%----------------------------------------------------------------------------

description() ->
    [{name, <<"topic">>},
     {description, <<"AMQP topic exchange, as per the AMQP specification">>}].

%% NB: This may return duplicate results in some situations (that's ok)
route(#exchange{name = X},
      #delivery{message = #basic_message{routing_keys = Routes}}) ->
    lists:append([begin
                    Words = split_topic_key(RKey),
                    mnesia:async_dirty(fun trie_match/2, [X, Words])
                  end || RKey <- Routes]).

validate(_X) -> ok.
create(_Tx, _X) -> ok.

recover(_Exchange, Bs) ->
    rabbit_misc:execute_mnesia_transaction(
        fun () ->
                lists:foreach(fun (B) -> internal_add_binding(B) end, Bs)
        end).

delete(true, #exchange{name = X}, _Bs) ->
    trie_remove_all_edges(X),
    trie_remove_all_bindings(X),
    ok;
delete(false, _Exchange, _Bs) ->
    ok.

add_binding(true, _Exchange, Binding) ->
    internal_add_binding(Binding);
add_binding(false, _Exchange, _Binding) ->
    ok.

remove_bindings(true, _X, Bs) ->
    ToDelete =
       lists:foldl(fun(B = #binding{source = X, destination = D}, Acc) ->
                           [{FinalNode, _} | _] = binding_path(B),
                           [{X, FinalNode, D} | Acc]
                   end, [], Bs),
    [trie_remove_binding(X, FinalNode, D) || {X, FinalNode, D} <- ToDelete],
    ok;
remove_bindings(false, _X, Bs) ->
    [rabbit_misc:execute_mnesia_transaction(
       fun() -> remove_path_if_empty(X, binding_path(B)) end)
                    || B = #binding{source = X} <- Bs],
    ok.

binding_path(#binding{source = X, key = K}) ->
    follow_down_get_path(X, split_topic_key(K)).

assert_args_equivalence(X, Args) ->
    rabbit_exchange:assert_args_equivalence(X, Args).

%%----------------------------------------------------------------------------

internal_add_binding(#binding{source = X, key = K, destination = D}) ->
    FinalNode = follow_down_create(X, split_topic_key(K)),
    trie_add_binding(X, FinalNode, D),
    ok.

trie_match(X, Words) ->
    trie_match(X, root, Words, []).

trie_match(X, Node, [], ResAcc) ->
    trie_match_part(X, Node, "#", fun trie_match_skip_any/4, [],
                    trie_bindings(X, Node) ++ ResAcc);
trie_match(X, Node, [W | RestW] = Words, ResAcc) ->
    lists:foldl(fun ({WArg, MatchFun, RestWArg}, Acc) ->
                        trie_match_part(X, Node, WArg, MatchFun, RestWArg, Acc)
                end, ResAcc, [{W, fun trie_match/4, RestW},
                              {"*", fun trie_match/4, RestW},
                              {"#", fun trie_match_skip_any/4, Words}]).

trie_match_part(X, Node, Search, MatchFun, RestW, ResAcc) ->
    case trie_child(X, Node, Search) of
        {ok, NextNode} -> MatchFun(X, NextNode, RestW, ResAcc);
        error          -> ResAcc
    end.

trie_match_skip_any(X, Node, [], ResAcc) ->
    trie_match(X, Node, [], ResAcc);
trie_match_skip_any(X, Node, [_ | RestW] = Words, ResAcc) ->
    trie_match_skip_any(X, Node, RestW,
                        trie_match(X, Node, Words, ResAcc)).

follow_down_create(X, Words) ->
    case follow_down_last_node(X, Words) of
        {ok, FinalNode}      -> FinalNode;
        {error, Node, RestW} -> lists:foldl(
                                  fun (W, CurNode) ->
                                          NewNode = new_node_id(),
                                          trie_add_edge(X, CurNode, NewNode, W),
                                          NewNode
                                  end, Node, RestW)
    end.

follow_down_last_node(X, Words) ->
    follow_down(X, fun (_, Node, _) -> Node end, root, Words).

follow_down_get_path(X, Words) ->
    {ok, Path} =
        follow_down(X, fun (W, Node, PathAcc) -> [{Node, W} | PathAcc] end,
                    [{root, none}], Words),
    Path.

follow_down(X, AccFun, Acc0, Words) ->
    follow_down(X, root, AccFun, Acc0, Words).

follow_down(_X, _CurNode, _AccFun, Acc, []) ->
    {ok, Acc};
follow_down(X, CurNode, AccFun, Acc, Words = [W | RestW]) ->
    case trie_child(X, CurNode, W) of
        {ok, NextNode} -> follow_down(X, NextNode, AccFun,
                                      AccFun(W, NextNode, Acc), RestW);
        error          -> {error, Acc, Words}
    end.

remove_path_if_empty(_, [{root, none}]) ->
    ok;
remove_path_if_empty(X, [{Node, W} | [{Parent, _} | _] = RestPath]) ->
    case trie_has_any_bindings(X, Node) orelse trie_has_any_children(X, Node) of
        true  -> ok;
        false -> trie_remove_edge(X, Parent, Node, W),
                 remove_path_if_empty(X, RestPath)
    end.

trie_child(X, Node, Word) ->
    case mnesia:read(rabbit_topic_trie_edge,
                     #trie_edge{exchange_name = X,
                                node_id       = Node,
                                word          = Word}) of
        [#topic_trie_edge{node_id = NextNode}] -> {ok, NextNode};
        []                                     -> error
    end.

trie_bindings(X, Node) ->
    MatchHead = #topic_trie_binding{
                    trie_binding = #trie_binding{exchange_name = X,
                                                 node_id       = Node,
                                                 destination   = '$1'}},
    mnesia:select(rabbit_topic_trie_binding, [{MatchHead, [], ['$1']}]).

trie_add_edge(X, FromNode, ToNode, W) ->
    trie_edge_op(X, FromNode, ToNode, W, fun mnesia:write/3).

trie_remove_edge(X, FromNode, ToNode, W) ->
    trie_edge_op(X, FromNode, ToNode, W, fun mnesia:delete_object/3).

trie_edge_op(X, FromNode, ToNode, W, Op) ->
    ok = Op(rabbit_topic_trie_edge,
            #topic_trie_edge{trie_edge = #trie_edge{exchange_name = X,
                                                    node_id       = FromNode,
                                                    word          = W},
                             node_id   = ToNode},
            write).

trie_add_binding(X, Node, D) ->
    trie_binding_op(X, Node, D, fun mnesia:write/3).

trie_remove_binding(X, Node, D) ->
    trie_binding_op(X, Node, D, fun mnesia:delete_object/3).

trie_binding_op(X, Node, D, Op) ->
    ok = Op(rabbit_topic_trie_binding,
            #topic_trie_binding{
                trie_binding = #trie_binding{exchange_name = X,
                                             node_id       = Node,
                                             destination   = D}},
            write).

trie_has_any_children(X, Node) ->
    has_any(rabbit_topic_trie_edge,
            #topic_trie_edge{trie_edge = #trie_edge{exchange_name = X,
                                                    node_id       = Node,
                                                    _             = '_'},
                             _         = '_'}).

trie_has_any_bindings(X, Node) ->
    has_any(rabbit_topic_trie_binding,
            #topic_trie_binding{
                trie_binding = #trie_binding{exchange_name = X,
                                             node_id       = Node,
                                             _             = '_'},
                _            = '_'}).

trie_remove_all_edges(X) ->
    remove_all(rabbit_topic_trie_edge,
               #topic_trie_edge{trie_edge = #trie_edge{exchange_name = X,
                                                       _             = '_'},
                                _         = '_'}).

trie_remove_all_bindings(X) ->
    remove_all(rabbit_topic_trie_binding,
               #topic_trie_binding{
                   trie_binding = #trie_binding{exchange_name = X, _ = '_'},
                   _            = '_'}).

has_any(Table, MatchHead) ->
    Select = mnesia:select(Table, [{MatchHead, [], ['$_']}], 1, read),
    select_while_no_result(Select) /= '$end_of_table'.

select_while_no_result({[], Cont}) ->
    select_while_no_result(mnesia:select(Cont));
select_while_no_result(Other) ->
    Other.

remove_all(Table, Pattern) ->
    lists:foreach(fun (R) -> mnesia:delete_object(Table, R, write) end,
                  mnesia:match_object(Table, Pattern, write)).

new_node_id() ->
    rabbit_guid:guid().

split_topic_key(Key) ->
    split_topic_key(Key, [], []).

split_topic_key(<<>>, [], []) ->
    [];
split_topic_key(<<>>, RevWordAcc, RevResAcc) ->
    lists:reverse([lists:reverse(RevWordAcc) | RevResAcc]);
split_topic_key(<<$., Rest/binary>>, RevWordAcc, RevResAcc) ->
    split_topic_key(Rest, [], [lists:reverse(RevWordAcc) | RevResAcc]);
split_topic_key(<<C:8, Rest/binary>>, RevWordAcc, RevResAcc) ->
    split_topic_key(Rest, [C | RevWordAcc], RevResAcc).

