%%%-------------------------------------------------------------------
%% @doc Tests for the static board model.
%%%-------------------------------------------------------------------
-module(stw_board_tests).

-include_lib("eunit/include/eunit.hrl").

dims_test() ->
    B = stw_board:default(),
    {W, H} = stw_board:dims(B),
    ?assert(W > 0),
    ?assert(H > 0).

border_is_wall_test() ->
    B = stw_board:default(),
    {W, H} = stw_board:dims(B),
    [?assertEqual(wall, stw_board:tile_at(B, {X, 0})) || X <- lists:seq(0, W - 1)],
    [?assertEqual(wall, stw_board:tile_at(B, {X, H - 1})) || X <- lists:seq(0, W - 1)],
    [?assertEqual(wall, stw_board:tile_at(B, {0, Y})) || Y <- lists:seq(0, H - 1)],
    [?assertEqual(wall, stw_board:tile_at(B, {W - 1, Y})) || Y <- lists:seq(0, H - 1)],
    ok.

spawns_are_open_test() ->
    B = stw_board:default(),
    Spawns = stw_board:spawns(B),
    ?assertEqual(4, length(Spawns)),
    [?assertEqual(spawn, stw_board:tile_at(B, C)) || C <- Spawns],
    ok.

%% The JSON grid must be rectangular: every row is exactly `width` chars.
grid_rectangular_test() ->
    B = stw_board:default(),
    #{<<"width">> := W, <<"height">> := H, <<"grid">> := Grid} = stw_board:to_json(B),
    ?assertEqual(H, length(Grid)),
    [?assertEqual(W, byte_size(Row)) || Row <- Grid],
    ok.

%% The map exposes its authored data nodes and extraction zone.
objectives_present_test() ->
    B = stw_board:default(),
    ?assert(length(stw_board:data_nodes(B)) >= 1),
    {EX, EY} = stw_board:extraction(B),
    ?assert(is_integer(EX)),
    ?assert(is_integer(EY)).

%% Data nodes and the extraction zone are hidden from the static grid: they
%% are revealed dynamically per player, so no $D or $X leaks into the rows.
objectives_hidden_from_grid_test() ->
    B = stw_board:default(),
    #{<<"grid">> := Grid} = stw_board:to_json(B),
    Joined = list_to_binary(Grid),
    ?assertEqual(nomatch, binary:match(Joined, <<"D">>)),
    ?assertEqual(nomatch, binary:match(Joined, <<"X">>)),
    ok.

%% Every non-wall tile must be reachable from a spawn: flood-fill from one
%% spawn and confirm it covers all open tiles. Catches map-authoring errors
%% that would strand data nodes or the extraction zone.
connectivity_test() ->
    B = stw_board:default(),
    {W, H} = stw_board:dims(B),
    Open = [{X, Y} || X <- lists:seq(0, W - 1), Y <- lists:seq(0, H - 1),
                      stw_board:tile_at(B, {X, Y}) =/= wall],
    [Start | _] = stw_board:spawns(B),
    Reached = flood(B, [Start], sets:new()),
    Missing = [C || C <- Open, not sets:is_element(C, Reached)],
    ?assertEqual([], Missing).

flood(_B, [], Seen) ->
    Seen;
flood(B, [C | Rest], Seen) ->
    case sets:is_element(C, Seen) orelse stw_board:tile_at(B, C) =:= wall of
        true ->
            flood(B, Rest, Seen);
        false ->
            flood(B, neighbours(C) ++ Rest, sets:add_element(C, Seen))
    end.

neighbours({X, Y}) ->
    [{X + 1, Y}, {X - 1, Y}, {X, Y + 1}, {X, Y - 1}].

%% -- Phase 9: map registry, alternate maps, dynamic collapse -----------

%% At least two maps are advertised for selection.
maps_list_test() ->
    Maps = stw_board:maps(),
    ?assert(length(Maps) >= 2),
    [?assert(maps:is_key(<<"id">>, M) andalso maps:is_key(<<"name">>, M))
     || M <- Maps],
    ok.

%% by_id/1 returns distinct, fully connected boards for known ids and
%% falls back to a valid board for unknown ids.
by_id_test() ->
    A = stw_board:by_id(<<"trench_alpha">>),
    Beta = stw_board:by_id(<<"trench_beta">>),
    ?assert(stw_board:connected(A)),
    ?assert(stw_board:connected(Beta)),
    ?assert(stw_board:connected(stw_board:by_id(<<"unknown_map">>))),
    ok.

%% The alternate map is fully connected from one of its spawns.
beta_connectivity_test() ->
    B = stw_board:by_id(<<"trench_beta">>),
    Open = stw_board:open_tiles(B),
    [Start | _] = stw_board:spawns(B),
    Reached = flood(B, [Start], sets:new()),
    Missing = [C || C <- Open, not sets:is_element(C, Reached)],
    ?assertEqual([], Missing).

%% A freshly built board is connected.
connected_default_test() ->
    ?assert(stw_board:connected(stw_board:default())).

%% collapse/2 turns a target tile into wall.
collapse_walls_tile_test() ->
    B = stw_board:default(),
    C = {8, 4},
    ?assertNotEqual(wall, stw_board:tile_at(B, C)),
    B1 = stw_board:collapse(B, C),
    ?assertEqual(wall, stw_board:tile_at(B1, C)).

%% connected/1 detects an isolated pocket: wall off all four neighbours of
%% an interior open tile and it can no longer reach the rest of the map.
connected_detects_isolation_test() ->
    B = stw_board:default(),
    C = {8, 4},
    ?assertNotEqual(wall, stw_board:tile_at(B, C)),
    B1 = lists:foldl(fun(N, Acc) -> stw_board:collapse(Acc, N) end,
                     B, [{9, 4}, {7, 4}, {8, 5}, {8, 3}]),
    ?assertNot(stw_board:connected(B1)).
