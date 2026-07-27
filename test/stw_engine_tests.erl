%%%-------------------------------------------------------------------
%% @doc Tests for the pure resolution engine.
%%%-------------------------------------------------------------------
-module(stw_engine_tests).

-include_lib("eunit/include/eunit.hrl").

%% --- fixtures ---------------------------------------------------------

%% An open room: trench everywhere inside a wall border, no currents.
open_board(W, H) ->
    Tiles = maps:from_list(
              [{{X, Y}, tile(X, Y, W, H)}
               || X <- lists:seq(0, W - 1), Y <- lists:seq(0, H - 1)]),
    #{width => W, height => H, tiles => Tiles,
      spawns => [], data_nodes => [], extraction => {0, 0},
      currents => #{}, turbulence => []}.

tile(X, Y, W, H) when X =:= 0; Y =:= 0; X =:= W - 1; Y =:= H - 1 -> wall;
tile(_, _, _, _) -> trench.

sub(X, Y, Facing) ->
    #{x => X, y => Y, facing => Facing, depth => <<"shallow">>,
      hull => 10, alive => true, data => 0}.

subd(X, Y, Facing, Depth) ->
    (sub(X, Y, Facing))#{depth => Depth}.

%% Program a single card (registers 1-4 fall through to holds).
one(Card) -> [Card].

final_pos(Final, Id) ->
    S = maps:get(Id, Final),
    {maps:get(x, S), maps:get(y, S)}.

find(Snapshot, Id) ->
    hd([M || M <- Snapshot, maps:get(<<"player_id">>, M) =:= Id]).

hull_of(Final, Id) ->
    maps:get(hull, maps:get(Id, Final)).

alive_of(Final, Id) ->
    maps:get(alive, maps:get(Id, Final)).

%% All events of a given type across every phase.
events_of(Phases, Type) ->
    [E || P <- Phases, E <- maps:get(<<"events">>, P),
          maps:get(<<"type">>, E) =:= Type].

%% --- movement ---------------------------------------------------------

forward_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"ahead_standard">>)}),
    ?assertEqual({3, 2}, final_pos(Final, <<"a">>)).

flank_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"ahead_flank">>)}),
    ?assertEqual({4, 2}, final_pos(Final, <<"a">>)).

reverse_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"reverse">>)}),
    ?assertEqual({1, 2}, final_pos(Final, <<"a">>)).

rotate_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"N">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"port_bank">>)}),
    ?assertEqual(<<"W">>, maps:get(facing, maps:get(<<"a">>, Final))).

depth_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"N">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"dive">>)}),
    ?assertEqual(<<"deep">>, maps:get(depth, maps:get(<<"a">>, Final))).

%% --- walls ------------------------------------------------------------

wall_blocks_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(1, 2, <<"W">>)},   % facing the west wall
    {Final, _, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"ahead_standard">>)}),
    ?assertEqual({1, 2}, final_pos(Final, <<"a">>)).

flank_stops_at_wall_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"W">>)},   % flank west: 1 ok, 2 hits wall
    {Final, _, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"ahead_flank">>)}),
    ?assertEqual({1, 2}, final_pos(Final, <<"a">>)).

%% --- multi-sub conflicts ---------------------------------------------

head_on_blocks_both_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(4, 2, <<"W">>)},
    P = #{<<"a">> => one(<<"ahead_standard">>), <<"b">> => one(<<"ahead_standard">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual({2, 2}, final_pos(Final, <<"a">>)),
    ?assertEqual({4, 2}, final_pos(Final, <<"b">>)).

swap_blocks_both_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(3, 2, <<"W">>)},
    P = #{<<"a">> => one(<<"ahead_standard">>), <<"b">> => one(<<"ahead_standard">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual({2, 2}, final_pos(Final, <<"a">>)),
    ?assertEqual({3, 2}, final_pos(Final, <<"b">>)).

follow_train_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(3, 2, <<"E">>)},
    P = #{<<"a">> => one(<<"ahead_standard">>), <<"b">> => one(<<"ahead_standard">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual({3, 2}, final_pos(Final, <<"a">>)),
    ?assertEqual({4, 2}, final_pos(Final, <<"b">>)).

%% --- currents & turbulence -------------------------------------------

current_drifts_test() ->
    B = (open_board(8, 6))#{currents => #{{5, 2} => {e, 1}}},
    Subs = #{<<"a">> => sub(5, 2, <<"N">>)},
    %% empty program -> holds; the current on (5,2) drifts one tile east.
    {Final, _, _} = stw_engine:resolve_round(B, Subs, #{}),
    ?assertEqual({6, 2}, final_pos(Final, <<"a">>)).

turbulence_rotates_test() ->
    B = (open_board(8, 6))#{turbulence => [{5, 2}]},
    Subs = #{<<"a">> => sub(5, 2, <<"N">>)},
    {_, Phases, _} = stw_engine:resolve_round(B, Subs, #{}),
    Reg0 = maps:get(<<"submarines">>, hd(Phases)),
    %% turbulence spins clockwise: N -> E after the first register.
    ?assertEqual(<<"E">>, maps:get(<<"facing">>, find(Reg0, <<"a">>))).

%% --- shape ------------------------------------------------------------

five_phases_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    {_, Phases, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"ahead_standard">>)}),
    ?assertEqual(5, length(Phases)),
    ?assertEqual([0, 1, 2, 3, 4], [maps:get(<<"register">>, P) || P <- Phases]).

snapshot_has_combat_fields_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    {_, Phases, _} = stw_engine:resolve_round(B, Subs, #{}),
    M = find(maps:get(<<"submarines">>, hd(Phases)), <<"a">>),
    ?assertEqual(10, maps:get(<<"hull">>, M)),
    ?assertEqual(true, maps:get(<<"alive">>, M)).

%% --- combat: torpedoes -----------------------------------------------

torpedo_hits_same_depth_test() ->
    B = open_board(10, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(5, 2, <<"W">>)},
    P = #{<<"a">> => one(<<"torpedo">>)},
    {Final, Phases, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual(8, hull_of(Final, <<"b">>)),   % 10 - 2
    ?assertEqual(10, hull_of(Final, <<"a">>)),
    ?assertEqual(1, length(events_of(Phases, <<"hit">>))).

torpedo_misses_different_depth_test() ->
    B = open_board(10, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>),
             <<"b">> => subd(5, 2, <<"W">>, <<"deep">>)},
    P = #{<<"a">> => one(<<"torpedo">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual(10, hull_of(Final, <<"b">>)).

torpedo_misses_into_wall_test() ->
    B = open_board(10, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"W">>)},   % nothing to the west but wall
    P = #{<<"a">> => one(<<"torpedo">>)},
    {_, Phases, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual([], events_of(Phases, <<"hit">>)).

%% --- combat: sonar ----------------------------------------------------

sonar_hits_across_depth_test() ->
    B = open_board(10, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>),
             <<"b">> => subd(5, 2, <<"W">>, <<"deep">>)},
    P = #{<<"a">> => one(<<"sonar_ping">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual(9, hull_of(Final, <<"b">>)).   % 10 - 1, depth ignored

%% --- combat: depth charge --------------------------------------------

depth_charge_delayed_test() ->
    B = open_board(8, 6),
    %% a arms at register 0 (on tile 2,2); b sits there. It goes off at reg 1.
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(2, 2, <<"W">>)},
    P = #{<<"a">> => [<<"depth_charge">>]},
    {Final, Phases, _} = stw_engine:resolve_round(B, Subs, P),
    %% no explosion in register 0, one in register 1
    Reg0 = hd(Phases),
    ?assertEqual([], [E || E <- maps:get(<<"events">>, Reg0),
                           maps:get(<<"type">>, E) =:= <<"explosion">>]),
    ?assertEqual(1, length(events_of(Phases, <<"explosion">>))),
    ?assertEqual(7, hull_of(Final, <<"b">>)).   % 10 - 3

depth_charge_last_register_detonates_test() ->
    B = open_board(8, 6),
    %% arm on the final register (index 4): must still detonate at round end.
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(2, 2, <<"W">>)},
    P = #{<<"a">> => [<<"port_bank">>, <<"port_bank">>, <<"port_bank">>,
                      <<"port_bank">>, <<"depth_charge">>]},
    {Final, Phases, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual(1, length(events_of(Phases, <<"explosion">>))),
    ?assertEqual(7, hull_of(Final, <<"b">>)).

%% --- combat: mines ----------------------------------------------------

mine_damages_and_scrambles_test() ->
    Mine = {4, 2},
    B = (open_board(8, 6))#{tiles =>
            maps:put(Mine, mine, maps:get(tiles, open_board(8, 6)))},
    %% a flanks east from (2,2): reg0 lands on the mine at (4,2); reg1 is
    %% scrambled to drift, so a stays put on reg1.
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    P = #{<<"a">> => [<<"ahead_flank">>, <<"ahead_standard">>,
                      <<"surface">>, <<"surface">>, <<"surface">>]},
    {Final, Phases, Effects} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual(7, hull_of(Final, <<"a">>)),        % 10 - 3
    ?assertEqual([Mine], maps:get(mines_cleared, Effects)),
    ?assertEqual({4, 2}, final_pos(Final, <<"a">>)), % scrambled reg1 = no move
    ?assertEqual(1, length(events_of(Phases, <<"mine">>))).

%% --- combat: thermal vents -------------------------------------------

vent_forces_shallow_test() ->
    Vent = {3, 2},
    B = (open_board(8, 6))#{tiles =>
            maps:put(Vent, vent, maps:get(tiles, open_board(8, 6)))},
    Subs = #{<<"a">> => subd(3, 2, <<"N">>, <<"deep">>)},
    {Final, _, _} = stw_engine:resolve_round(B, Subs, #{}),
    ?assertEqual(<<"shallow">>, maps:get(depth, maps:get(<<"a">>, Final))).

%% --- combat: ramming & destruction -----------------------------------

ram_damages_both_test() ->
    B = open_board(8, 6),
    %% a moves east into b (stationary): both take ram damage.
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(3, 2, <<"N">>)},
    P = #{<<"a">> => one(<<"ahead_standard">>)},
    {Final, Phases, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual({2, 2}, final_pos(Final, <<"a">>)),   % blocked by b
    ?assertEqual(9, hull_of(Final, <<"a">>)),
    ?assertEqual(9, hull_of(Final, <<"b">>)),
    ?assert(length(events_of(Phases, <<"ram">>)) >= 1).

destruction_marks_wreck_test() ->
    B = open_board(10, 6),
    %% b starts at hull 1; one torpedo destroys it.
    Subs = #{<<"a">> => sub(2, 2, <<"E">>),
             <<"b">> => (sub(5, 2, <<"W">>))#{hull => 1}},
    P = #{<<"a">> => one(<<"torpedo">>)},
    {Final, Phases, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual(false, alive_of(Final, <<"b">>)),
    ?assertEqual(1, length(events_of(Phases, <<"destroyed">>))).

%% --- depth interactions ----------------------------------------------

%% Depth charges are the one weapon that crosses layers: a charge armed by a
%% shallow sub still damages a deep sub sharing its tile when it detonates.
depth_charge_hits_across_depth_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>),
             <<"b">> => subd(2, 2, <<"W">>, <<"deep">>)},
    P = #{<<"a">> => [<<"depth_charge">>]},
    {Final, Phases, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual(7, hull_of(Final, <<"b">>)),   % 10 - 3, depth ignored
    ?assertEqual(1, length(events_of(Phases, <<"explosion">>))).

%% --- tactical: EMP burst ---------------------------------------------

emp_disables_adjacent_register_test() ->
    B = open_board(8, 6),
    %% a fires EMP at register 0; b is adjacent and would flank east on
    %% register 1. The EMP scrambles that register to drift, so b stays put.
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(3, 2, <<"E">>)},
    P = #{<<"a">> => [<<"emp_burst">>],
          <<"b">> => [<<"surface">>, <<"ahead_standard">>, <<"surface">>,
                      <<"surface">>, <<"surface">>]},
    {Final, Phases, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual({3, 2}, final_pos(Final, <<"b">>)),
    ?assertEqual(1, length(events_of(Phases, <<"emp_burst">>))),
    ?assertEqual(1, length(events_of(Phases, <<"disabled">>))).

emp_no_target_is_noop_test() ->
    B = open_board(8, 6),
    %% b is out of range: the EMP finds no target and b's register 1 still
    %% advances it east one tile.
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(5, 2, <<"E">>)},
    P = #{<<"a">> => [<<"emp_burst">>],
          <<"b">> => [<<"surface">>, <<"ahead_standard">>, <<"surface">>,
                      <<"surface">>, <<"surface">>]},
    {Final, Phases, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual({6, 2}, final_pos(Final, <<"b">>)),
    ?assertEqual([], events_of(Phases, <<"emp_burst">>)),
    ?assertEqual([], events_of(Phases, <<"disabled">>)).

%% --- tactical: decoy torpedo -----------------------------------------

decoy_projects_false_contact_test() ->
    B = open_board(10, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    P = #{<<"a">> => one(<<"decoy_torpedo">>)},
    {_, Phases, Effects} = stw_engine:resolve_round(B, Subs, P),
    Decoys = maps:get(decoys, Effects),
    ?assertMatch([{<<"a">>, {_, 2}}], Decoys),
    [{<<"a">>, {DX, _}}] = Decoys,
    ?assert(DX > 2),
    ?assertEqual(1, length(events_of(Phases, <<"decoy">>))).

