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
      hull => 10, data => 0}.

%% Program a single card (registers 1-4 fall through to holds).
one(Card) -> [Card].

final_pos(Final, Id) ->
    S = maps:get(Id, Final),
    {maps:get(x, S), maps:get(y, S)}.

find(Snapshot, Id) ->
    hd([M || M <- Snapshot, maps:get(<<"player_id">>, M) =:= Id]).

%% --- movement ---------------------------------------------------------

forward_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    {Final, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"ahead_standard">>)}),
    ?assertEqual({3, 2}, final_pos(Final, <<"a">>)).

flank_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    {Final, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"ahead_flank">>)}),
    ?assertEqual({4, 2}, final_pos(Final, <<"a">>)).

reverse_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    {Final, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"reverse">>)}),
    ?assertEqual({1, 2}, final_pos(Final, <<"a">>)).

rotate_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"N">>)},
    {Final, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"port_bank">>)}),
    ?assertEqual(<<"W">>, maps:get(facing, maps:get(<<"a">>, Final))).

depth_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"N">>)},
    {Final, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"dive">>)}),
    ?assertEqual(<<"deep">>, maps:get(depth, maps:get(<<"a">>, Final))).

%% --- walls ------------------------------------------------------------

wall_blocks_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(1, 2, <<"W">>)},   % facing the west wall
    {Final, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"ahead_standard">>)}),
    ?assertEqual({1, 2}, final_pos(Final, <<"a">>)).

flank_stops_at_wall_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"W">>)},   % flank west: 1 ok, 2 hits wall
    {Final, _} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"ahead_flank">>)}),
    ?assertEqual({1, 2}, final_pos(Final, <<"a">>)).

%% --- multi-sub conflicts ---------------------------------------------

head_on_blocks_both_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(4, 2, <<"W">>)},
    P = #{<<"a">> => one(<<"ahead_standard">>), <<"b">> => one(<<"ahead_standard">>)},
    {Final, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual({2, 2}, final_pos(Final, <<"a">>)),
    ?assertEqual({4, 2}, final_pos(Final, <<"b">>)).

swap_blocks_both_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(3, 2, <<"W">>)},
    P = #{<<"a">> => one(<<"ahead_standard">>), <<"b">> => one(<<"ahead_standard">>)},
    {Final, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual({2, 2}, final_pos(Final, <<"a">>)),
    ?assertEqual({3, 2}, final_pos(Final, <<"b">>)).

follow_train_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>), <<"b">> => sub(3, 2, <<"E">>)},
    P = #{<<"a">> => one(<<"ahead_standard">>), <<"b">> => one(<<"ahead_standard">>)},
    {Final, _} = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual({3, 2}, final_pos(Final, <<"a">>)),
    ?assertEqual({4, 2}, final_pos(Final, <<"b">>)).

%% --- currents & turbulence -------------------------------------------

current_drifts_test() ->
    B = (open_board(8, 6))#{currents => #{{5, 2} => {e, 1}}},
    Subs = #{<<"a">> => sub(5, 2, <<"N">>)},
    %% empty program -> holds; the current on (5,2) drifts one tile east.
    {Final, _} = stw_engine:resolve_round(B, Subs, #{}),
    ?assertEqual({6, 2}, final_pos(Final, <<"a">>)).

turbulence_rotates_test() ->
    B = (open_board(8, 6))#{turbulence => [{5, 2}]},
    Subs = #{<<"a">> => sub(5, 2, <<"N">>)},
    {_, Phases} = stw_engine:resolve_round(B, Subs, #{}),
    Reg0 = maps:get(<<"submarines">>, hd(Phases)),
    %% turbulence spins clockwise: N -> E after the first register.
    ?assertEqual(<<"E">>, maps:get(<<"facing">>, find(Reg0, <<"a">>))).

%% --- shape ------------------------------------------------------------

five_phases_test() ->
    B = open_board(8, 6),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>)},
    {_, Phases} = stw_engine:resolve_round(B, Subs, #{<<"a">> => one(<<"ahead_standard">>)}),
    ?assertEqual(5, length(Phases)),
    ?assertEqual([0, 1, 2, 3, 4], [maps:get(<<"register">>, P) || P <- Phases]).
