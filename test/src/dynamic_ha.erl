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
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2014 GoPivotal, Inc.  All rights reserved.
%%
-module(dynamic_ha).

%% rabbit_tests:test_dynamic_mirroring() is a unit test which should
%% test the logic of what all the policies decide to do, so we don't
%% need to exhaustively test that here. What we need to test is that:
%%
%% * Going from non-mirrored to mirrored works and vice versa
%% * Changing policy can add / remove mirrors and change the master
%% * Adding a node will create a new mirror when there are not enough nodes
%%   for the policy
%% * Removing a node will not create a new mirror even if the policy
%%   logic wants it (since this gives us a good way to lose messages
%%   on cluster shutdown, by repeated failover to new nodes)
%%
%% The first two are change_policy, the last two are change_cluster

-compile(export_all).
-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-define(QNAME, <<"ha.test">>).
-define(POLICY, <<"^ha.test$">>). %% " emacs
-define(VHOST, <<"/">>).

-import(rabbit_test_util, [set_ha_policy/3, set_ha_policy/4,
                           clear_policy/2, a2b/1]).
-import(rabbit_misc, [pget/2]).

change_policy_with() -> cluster_abc.
change_policy([CfgA, _CfgB, _CfgC] = Cfgs) ->
    ACh = pget(channel, CfgA),
    [A, B, C] = [pget(node, Cfg) || Cfg <- Cfgs],

    %% When we first declare a queue with no policy, it's not HA.
    amqp_channel:call(ACh, #'queue.declare'{queue = ?QNAME}),
    assert_slaves(A, ?QNAME, {A, ''}),

    %% Give it policy "all", it becomes HA and gets all mirrors
    set_ha_policy(CfgA, ?POLICY, <<"all">>),
    assert_slaves(A, ?QNAME, {A, [B, C]}),

    %% Give it policy "nodes", it gets specific mirrors
    set_ha_policy(CfgA, ?POLICY, <<"nodes">>, [a2b(A), a2b(B)]),
    assert_slaves(A, ?QNAME, {A, [B]}),

    %% Now explicitly change the mirrors
    set_ha_policy(CfgA, ?POLICY, <<"nodes">>, [a2b(A), a2b(C)]),
    assert_slaves(A, ?QNAME, {A, [C]}, [{A, [B, C]}]),

    %% Clear the policy, and we go back to non-mirrored
    clear_policy(CfgA, ?POLICY),
    assert_slaves(A, ?QNAME, {A, ''}),

    %% Test switching "away" from an unmirrored node
    set_ha_policy(CfgA, ?POLICY, <<"nodes">>, [a2b(B), a2b(C)]),
    assert_slaves(A, ?QNAME, {A, [B, C]}, [{A, [B]}, {A, [C]}]),

    ok.

change_cluster_with() -> cluster_abc.
change_cluster([CfgA, _CfgB, _CfgC] = CfgsABC) ->
    ACh = pget(channel, CfgA),
    [A, B, C] = [pget(node, Cfg) || Cfg <- CfgsABC],

    amqp_channel:call(ACh, #'queue.declare'{queue = ?QNAME}),
    assert_slaves(A, ?QNAME, {A, ''}),

    %% Give it policy exactly 4, it should mirror to all 3 nodes
    set_ha_policy(CfgA, ?POLICY, <<"exactly">>, 4),
    assert_slaves(A, ?QNAME, {A, [B, C]}),

    %% Add D and E, D joins in
    [CfgD, CfgE] = CfgsDE = rabbit_test_configs:start_nodes(CfgA, [d, e], 5675),
    D = pget(node, CfgD),
    rabbit_test_configs:add_to_cluster(CfgsABC, CfgsDE),
    assert_slaves(A, ?QNAME, {A, [B, C, D]}),

    %% Remove D, E does not join in
    rabbit_test_configs:stop_node(CfgD),
    assert_slaves(A, ?QNAME, {A, [B, C]}),

    %% Clean up since we started this by hand
    rabbit_test_configs:stop_node(CfgE),
    ok.

rapid_change_with() -> cluster_abc.
rapid_change([CfgA, _CfgB, _CfgC]) ->
    ACh = pget(channel, CfgA),
    A = pget(node, CfgA),
    Self = self(),
    spawn_link(
      fun() ->
              [rapid_amqp_ops(ACh, I) || I <- lists:seq(1, 100)],
              Self ! done
      end),
    rapid_loop(CfgA),
    ok.

rapid_amqp_ops(Ch, I) ->
    Payload = list_to_binary(integer_to_list(I)),
    amqp_channel:call(Ch, #'queue.declare'{queue = ?QNAME}),
    amqp_channel:cast(Ch, #'basic.publish'{exchange = <<"">>,
                                           routing_key = ?QNAME},
                      #amqp_msg{payload = Payload}),
    amqp_channel:subscribe(Ch, #'basic.consume'{queue    = ?QNAME,
                                                no_ack   = true}, self()),
    receive #'basic.consume_ok'{} -> ok
    end,
    receive {#'basic.deliver'{}, #amqp_msg{payload = Payload}} ->
            ok
    end,
    amqp_channel:call(Ch, #'queue.delete'{queue = ?QNAME}).

rapid_loop(Cfg) ->
    receive done ->
            ok
    after 0 ->
            set_ha_policy(Cfg, ?POLICY, <<"all">>),
            clear_policy(Cfg, ?POLICY),
            rapid_loop(Cfg)
    end.

%%----------------------------------------------------------------------------

assert_slaves(RPCNode, QName, Exp) ->
    assert_slaves(RPCNode, QName, Exp, []).

assert_slaves(RPCNode, QName, Exp, PermittedIntermediate) ->
    assert_slaves0(RPCNode, QName, Exp,
                  [{get(previous_exp_m_node), get(previous_exp_s_nodes)} |
                   PermittedIntermediate]).

assert_slaves0(RPCNode, QName, {ExpMNode, ExpSNodes}, PermittedIntermediate) ->
    Q = find_queue(QName, RPCNode),
    Pid = proplists:get_value(pid, Q),
    SPids = proplists:get_value(slave_pids, Q),
    ActMNode = node(Pid),
    ActSNodes = case SPids of
                    '' -> '';
                    _  -> [node(SPid) || SPid <- SPids]
                end,
    case ExpMNode =:= ActMNode andalso equal_list(ExpSNodes, ActSNodes) of
        false ->
            %% It's an async change, so if nothing has changed let's
            %% just wait - of course this means if something does not
            %% change when expected then we time out the test which is
            %% a bit tedious
            case [found || {PermMNode, PermSNodes} <- PermittedIntermediate,
                           PermMNode =:= ActMNode,
                           equal_list(PermSNodes, ActSNodes)] of
                [] -> ct:fail("Expected ~p / ~p, got ~p / ~p~nat ~p~n",
                              [ExpMNode, ExpSNodes, ActMNode, ActSNodes,
                               get_stacktrace()]);
                _  -> timer:sleep(100),
                      assert_slaves0(RPCNode, QName, {ExpMNode, ExpSNodes},
                                     PermittedIntermediate)
            end;
        true ->
            put(previous_exp_m_node, ExpMNode),
            put(previous_exp_s_nodes, ExpSNodes),
            ok
    end.

equal_list('',    '')   -> true;
equal_list('',    _Act) -> false;
equal_list(_Exp,  '')   -> false;
equal_list([],    [])   -> true;
equal_list(_Exp,  [])   -> false;
equal_list([],    _Act) -> false;
equal_list([H|T], Act)  -> case lists:member(H, Act) of
                               true  -> equal_list(T, Act -- [H]);
                               false -> false
                           end.

find_queue(QName, RPCNode) ->
    Qs = rpc:call(RPCNode, rabbit_amqqueue, info_all, [?VHOST], infinity),
    case find_queue0(QName, Qs) of
        did_not_find_queue -> timer:sleep(100),
                              find_queue(QName, RPCNode);
        Q -> Q
    end.

find_queue0(QName, Qs) ->
    case [Q || Q <- Qs, proplists:get_value(name, Q) =:=
                   rabbit_misc:r(?VHOST, queue, QName)] of
        [R] -> R;
        []  -> did_not_find_queue
    end.

get_stacktrace() ->
    try
        throw(e)
    catch
        _:e ->
            erlang:get_stacktrace()
    end.
