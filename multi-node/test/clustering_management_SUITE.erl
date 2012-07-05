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
%% Copyright (c) 2007-2012 VMware, Inc.  All rights reserved.
%%
-module(clustering_management_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("systest/include/systest.hrl").

-include_lib("amqp_client/include/amqp_client.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1,

         join_and_part_cluster/1, join_cluster_bad_operations/1,
         join_to_start_interval/1, remove_node_test/1,
         change_node_type_test/1, change_cluster_when_node_offline/1,
         recluster_test/1
        ]).

suite() -> [{timetrap, {seconds, 60}}].

all() ->
    [join_and_part_cluster, join_cluster_bad_operations, join_to_start_interval,
     remove_node_test, change_node_type_test, change_cluster_when_node_offline,
     recluster_test].

init_per_suite(Config) ->
    Config.
end_per_suite(_Config) ->
    ok.

join_and_part_cluster(Config) ->
    [Rabbit, Hare, Bunny] = cluster_nodes(Config),
    check_not_clustered(Rabbit),
    check_not_clustered(Hare),
    check_not_clustered(Bunny),

    ok = stop_app(Rabbit),
    ok = join_cluster(Rabbit, Bunny),
    ok = start_app(Rabbit),

    check_cluster_status(
      {[Bunny, Rabbit], [Bunny, Rabbit], [Bunny, Rabbit]},
      [Rabbit, Bunny]),

    ok = stop_app(Hare),
    ok = join_cluster(Hare, Bunny, true),
    ok = start_app(Hare),

    check_cluster_status(
      {[Bunny, Hare, Rabbit], [Bunny, Rabbit], [Bunny, Hare, Rabbit]},
      [Rabbit, Hare, Bunny]),

    ok = stop_app(Rabbit),
    ok = reset(Rabbit),
    ok = start_app(Rabbit),

    check_cluster_status({[Rabbit], [Rabbit], [Rabbit]}, [Rabbit]),
    check_cluster_status({[Bunny, Hare], [Bunny], [Bunny, Hare]},
                         [Hare, Bunny]),

    ok = stop_app(Hare),
    ok = reset(Hare),
    ok = start_app(Hare),

    check_not_clustered(Hare),
    check_not_clustered(Bunny).

join_cluster_bad_operations(Config) ->
    [Rabbit, Hare, Bunny] = cluster_nodes(Config),

    %% Non-existant node
    ok = stop_app(Rabbit),
    check_failure(fun () -> join_cluster(Rabbit, non@existant) end),
    ok = start_app(Rabbit),
    check_not_clustered(Rabbit),

    %% Trying to cluster with mnesia running
    check_failure(fun () -> join_cluster(Rabbit, Bunny) end),
    check_not_clustered(Rabbit),

    %% Trying to cluster the node with itself
    ok = stop_app(Rabbit),
    check_failure(fun () -> join_cluster(Rabbit, Rabbit) end),
    ok = start_app(Rabbit),
    check_not_clustered(Rabbit),

    %% Fail if trying to cluster with already clustered node
    ok = stop_app(Rabbit),
    join_cluster(Rabbit, Hare),
    ok = start_app(Rabbit),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Rabbit, Hare]},
                         [Rabbit, Hare]),
    ok = stop_app(Rabbit),
    check_failure(fun () -> join_cluster(Rabbit, Hare) end),
    ok = start_app(Rabbit),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Rabbit, Hare]},
                         [Rabbit, Hare]),

    %% Cleanup
    ok = stop_app(Rabbit),
    reset(Rabbit),
    ok = start_app(Rabbit),
    check_not_clustered(Rabbit),
    check_not_clustered(Hare),

    %% Do not let the node leave the cluster or reset if it's the only
    %% ram node
    ok = stop_app(Hare),
    ok = join_cluster(Hare, Rabbit, true),
    ok = start_app(Hare),
    check_cluster_status({[Rabbit, Hare], [Rabbit], [Rabbit, Hare]},
                         [Rabbit, Hare]),
    ok = stop_app(Hare),
    check_failure(fun () -> join_cluster(Rabbit, Bunny) end),
    check_failure(fun () -> reset(Rabbit) end),
    ok = start_app(Hare),
    check_cluster_status({[Rabbit, Hare], [Rabbit], [Rabbit, Hare]},
                         [Rabbit, Hare]).

%% This tests that the nodes in the cluster are notified immediately of a node
%% join, and not just after the app is started.
join_to_start_interval(Config) ->
    [Rabbit, Hare, _Bunny] = cluster_nodes(Config),

    ok = stop_app(Rabbit),
    ok = join_cluster(Rabbit, Hare),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Hare]},
                         [Rabbit, Hare]),
    ok = start_app(Rabbit),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Rabbit, Hare]},
                         [Rabbit, Hare]).

remove_node_test(Config) ->
    [Rabbit, Hare, Bunny] = cluster_nodes(Config),

    %% Trying to remove a node not in the cluster should fail
    check_failure(fun () -> remove_node(Hare, Rabbit) end),

    ok = stop_app(Rabbit),
    join_cluster(Rabbit, Hare),
    ok = start_app(Rabbit),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Hare, Rabbit]},
                         [Rabbit, Hare]),

    %% Trying to remove an online node should fail
    check_failure(fun () -> remove_node(Hare, Rabbit) end),

    ok = stop_app(Rabbit),
    check_failure(fun () -> remove_node(Hare, Rabbit, true) end),
    ok = remove_node(Hare, Rabbit),
    check_not_clustered(Hare),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Hare]},
                         [Rabbit]),

    %% Now we can't start Rabbit since it thinks that it's still in the cluster
    %% with Hare, while Hare disagrees.
    check_failure(fun () -> start_app(Rabbit) end),

    ok = reset(Rabbit),
    ok = start_app(Rabbit),
    check_not_clustered(Rabbit),

    %% Now we remove Rabbit from an offline node.
    ok = stop_app(Bunny),
    ok = join_cluster(Bunny, Hare),
    ok = start_app(Bunny),
    ok = stop_app(Rabbit),
    ok = join_cluster(Rabbit, Hare),
    ok = start_app(Rabbit),
    check_cluster_status(
      {[Rabbit, Hare, Bunny], [Rabbit, Hare, Bunny], [Rabbit, Hare, Bunny]},
      [Rabbit, Hare, Bunny]),
    ok = stop_app(Rabbit),
    ok = stop_app(Hare),
    ok = stop_app(Bunny),
    %% Rabbit was not the second-to-last to go down
    check_failure(fun () -> remove_node(Rabbit, Bunny, true) end),
    %% This is fine but we need the flag
    check_failure(fun () -> remove_node(Hare, Bunny) end),
    ok = remove_node(Hare, Bunny, true),
    ok = start_app(Hare),
    ok = start_app(Rabbit),
    %% Bunny still thinks its clustered with Rabbit and Hare
    check_failure(fun () -> start_app(Bunny) end),
    ok = reset(Bunny),
    ok = start_app(Bunny),
    check_not_clustered(Bunny),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Rabbit, Hare]},
                         [Rabbit, Hare]).

change_node_type_test(Config) ->
    [Rabbit, Hare, _Bunny] = cluster_nodes(Config),

    %% Trying to change the ram node when not clustered should always fail
    ok = stop_app(Rabbit),
    check_failure(fun () -> change_node_type(Rabbit, ram) end),
    check_failure(fun () -> change_node_type(Rabbit, disc) end),
    ok = start_app(Rabbit),

    ok = stop_app(Rabbit),
    join_cluster(Rabbit, Hare),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Hare]},
                         [Rabbit, Hare]),
    change_node_type(Rabbit, ram),
    check_cluster_status({[Rabbit, Hare], [Hare], [Hare]},
                         [Rabbit, Hare]),
    change_node_type(Rabbit, disc),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Hare]},
                         [Rabbit, Hare]),
    change_node_type(Rabbit, ram),
    ok = start_app(Rabbit),
    check_cluster_status({[Rabbit, Hare], [Hare], [Hare, Rabbit]},
                         [Rabbit, Hare]),

    %% Changing to ram when you're the only ram node should fail
    ok = stop_app(Hare),
    check_failure(fun () -> change_node_type(Hare, ram) end),
    ok = start_app(Hare).

change_cluster_when_node_offline(Config) ->
    [Rabbit, Hare, Bunny] = cluster_nodes(Config),

    %% Cluster the three notes
    ok = stop_app(Rabbit),
    join_cluster(Rabbit, Hare),
    ok = start_app(Rabbit),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Hare, Rabbit]},
                         [Rabbit, Hare]),

    ok = stop_app(Bunny),
    join_cluster(Bunny, Hare),
    ok = start_app(Bunny),
    check_cluster_status(
      {[Rabbit, Hare, Bunny], [Rabbit, Hare, Bunny], [Rabbit, Hare, Bunny]},
      [Rabbit, Hare, Bunny]),

    %% Bring down Rabbit, and remove Bunny from the cluster while
    %% Rabbit is offline
    ok = stop_app(Rabbit),
    ok = stop_app(Bunny),
    ok = reset(Bunny),
    check_cluster_status({[Bunny], [Bunny], []}, [Bunny]),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Hare]}, [Hare]),
    check_cluster_status(
      {[Rabbit, Hare, Bunny], [Rabbit, Hare, Bunny], [Hare, Bunny]},
      [Rabbit]),

    %% Bring Rabbit back up
    ok = start_app(Rabbit),
    check_cluster_status({[Rabbit, Hare], [Rabbit, Hare], [Rabbit, Hare]},
                         [Rabbit, Hare]),
    ok = start_app(Bunny),
    check_not_clustered(Bunny),

    %% Now the same, but Rabbit is a RAM node, and we bring up Bunny
    %% before
    ok = stop_app(Rabbit),
    ok = change_node_type(Rabbit, ram),
    ok = start_app(Rabbit),
    ok = stop_app(Bunny),
    ok = join_cluster(Bunny, Hare),
    ok = start_app(Bunny),
    check_cluster_status(
      {[Rabbit, Hare, Bunny], [Hare, Bunny], [Rabbit, Hare, Bunny]},
      [Rabbit, Hare, Bunny]),
    ok = stop_app(Rabbit),
    ok = stop_app(Bunny),
    ok = reset(Bunny),
    ok = start_app(Bunny),
    check_not_clustered(Bunny),
    check_cluster_status({[Rabbit, Hare], [Hare], [Hare]}, [Hare]),
    check_cluster_status(
      {[Rabbit, Hare, Bunny], [Hare, Bunny], [Hare, Bunny]},
      [Rabbit]),
    ok = start_app(Rabbit),
    check_cluster_status({[Rabbit, Hare], [Hare], [Rabbit, Hare]},
                         [Rabbit, Hare]),
    check_not_clustered(Bunny).

recluster_test(Config) ->
    [Rabbit, Hare, Bunny] = cluster_nodes(Config),

    %% Mnesia is running...
    check_failure(fun () -> recluster(Rabbit, Hare) end),

    ok = stop_app(Rabbit),
    ok = join_cluster(Rabbit, Hare),
    ok = stop_app(Bunny),
    ok = join_cluster(Bunny, Hare),
    ok = start_app(Bunny),
    ok = stop_app(Hare),
    ok = reset(Hare),
    ok = start_app(Hare),
    check_failure(fun () -> start_app(Rabbit) end),
    %% Bogus node
    check_failure(fun () -> recluster(Rabbit, non@existant) end),
    %% Inconsisent node
    check_failure(fun () -> recluster(Rabbit, Hare) end),
    ok = recluster(Rabbit, Bunny),
    ok = start_app(Rabbit),
    check_not_clustered(Hare),
    check_cluster_status({[Rabbit, Bunny], [Rabbit, Bunny], [Rabbit, Bunny]},
                         [Rabbit, Bunny]).

%% ----------------------------------------------------------------------------
%% Internal utils

cluster_nodes(Config) ->
    Cluster = systest:active_cluster(Config),
    systest_cluster:print_status(Cluster),
    [N || {N, _} <- systest:cluster_nodes(Cluster)].

check_cluster_status(Status0, Nodes) ->
    SortStatus =
        fun ({All, Disc, Running}) ->
                {lists:sort(All), lists:sort(Disc), lists:sort(Running)}
        end,
    Status = {AllNodes, _, _} = SortStatus(Status0),
    lists:foreach(
      fun (Node) ->
              ?assertEqual(AllNodes =/= [Node],
                           rpc:call(Node, rabbit_mnesia, is_clustered, [])),
              ?assertEqual(
                 Status, SortStatus(rabbit_ha_test_utils:cluster_status(Node)))
      end, Nodes).

check_not_clustered(Node) ->
    check_cluster_status({[Node], [Node], [Node]}, [Node]).

check_failure(Fun) ->
    case catch Fun() of
        {error, Reason}            -> Reason;
        {badrpc, {'EXIT', Reason}} -> Reason
    end.

stop_app(Node) ->
    rabbit_ha_test_utils:control_action(stop_app, Node).

start_app(Node) ->
    rabbit_ha_test_utils:control_action(start_app, Node).

join_cluster(Node, To) ->
    join_cluster(Node, To, false).

join_cluster(Node, To, Ram) ->
    rabbit_ha_test_utils:control_action(
      join_cluster, Node, [atom_to_list(To)], [{"--ram", Ram}]).

reset(Node) ->
    rabbit_ha_test_utils:control_action(reset, Node).

remove_node(Node, Removee, RemoveWhenOffline) ->
    rabbit_ha_test_utils:control_action(
      remove_node, Node, [atom_to_list(Removee)],
      [{"--offline", RemoveWhenOffline}]).

remove_node(Node, Removee) ->
    remove_node(Node, Removee, false).

change_node_type(Node, Type) ->
    rabbit_ha_test_utils:control_action(change_node_type, Node,
                                        [atom_to_list(Type)]).

recluster(Node, DiscoveryNode) ->
    rabbit_ha_test_utils:control_action(recluster, Node,
                                        [atom_to_list(DiscoveryNode)]).
