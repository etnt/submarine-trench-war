%%%-------------------------------------------------------------------
%% @doc Unit tests for the pure fog-of-war visibility engine.
%% @end
%%%-------------------------------------------------------------------
-module(stw_vision_tests).

-include_lib("eunit/include/eunit.hrl").

%% A submarine always sees the tile it sits on.
own_tile_visible_test() ->
    B = board(11, 11, []),
    S = sub(5, 5, <<"E">>, <<"shallow">>),
    ?assert(stw_vision:sees(B, S, passive, {5, 5})),
    ?assert(lists:member({5, 5}, stw_vision:visible_tiles(B, S, passive))).

%% The near radius is all-around: a passive sub sees the tiles directly
%% behind it even though its cone faces the other way.
near_radius_all_around_test() ->
    B = board(11, 11, []),
    S = sub(5, 5, <<"E">>, <<"shallow">>),
    %% two tiles west (behind) is within the passive near radius of 2
    ?assert(stw_vision:sees(B, S, passive, {3, 5})),
    %% one tile north and south too
    ?assert(stw_vision:sees(B, S, passive, {5, 4})),
    ?assert(stw_vision:sees(B, S, passive, {5, 6})).

%% The forward cone reaches the passive cone length (4) but no further.
forward_cone_test() ->
    B = board(11, 11, []),
    S = sub(5, 5, <<"E">>, <<"shallow">>),
    ?assert(stw_vision:sees(B, S, passive, {9, 5})),      %% 4 ahead
    ?assertNot(stw_vision:sees(B, S, passive, {10, 5})).  %% 5 ahead

%% A wall between the viewer and a cone tile blocks line of sight, but the
%% same tile is visible once the wall is gone.
wall_blocks_los_test() ->
    Open = board(11, 11, []),
    Blocked = board(11, 11, [{6, 5}]),
    S = sub(5, 5, <<"E">>, <<"shallow">>),
    ?assert(stw_vision:sees(Open, S, passive, {8, 5})),
    ?assertNot(stw_vision:sees(Blocked, S, passive, {8, 5})),
    %% the blocking wall itself is still visible (endpoints are not occluded)
    ?assert(stw_vision:sees(Blocked, S, passive, {6, 5})).

%% Diving deep shortens the forward cone by one tile.
deep_shortens_cone_test() ->
    B = board(11, 11, []),
    Shallow = sub(5, 5, <<"E">>, <<"shallow">>),
    Deep = sub(5, 5, <<"E">>, <<"deep">>),
    ?assert(stw_vision:sees(B, Shallow, passive, {9, 5})),   %% 4 ahead
    ?assertNot(stw_vision:sees(B, Deep, passive, {9, 5})),   %% cone now 3
    ?assert(stw_vision:sees(B, Deep, passive, {8, 5})).      %% 3 ahead ok

%% Active sonar has a wider near radius than passive.
active_wider_near_test() ->
    B = board(11, 11, []),
    S = sub(5, 5, <<"E">>, <<"shallow">>),
    %% three tiles behind the sub: outside the passive near radius and cone,
    %% but inside the active near radius of 3
    ?assertNot(stw_vision:sees(B, S, passive, {2, 5})),
    ?assert(stw_vision:sees(B, S, active, {2, 5})).

%% Active sonar also reaches further forward than passive.
active_longer_cone_test() ->
    B = board(11, 11, []),
    S = sub(5, 5, <<"E">>, <<"shallow">>),
    ?assertNot(stw_vision:sees(B, S, passive, {10, 5})),  %% 5 ahead
    ?assert(stw_vision:sees(B, S, active, {10, 5})).

%% --- helpers ----------------------------------------------------------

sub(X, Y, Facing, Depth) ->
    #{x => X, y => Y, facing => Facing, depth => Depth}.

%% A rectangular board that is open trench everywhere except the given
%% wall coordinates.
board(W, H, Walls) ->
    Tiles = maps:from_list(
              [{{X, Y}, tile({X, Y}, Walls)}
               || X <- lists:seq(0, W - 1), Y <- lists:seq(0, H - 1)]),
    #{width => W, height => H, tiles => Tiles}.

tile(C, Walls) ->
    case lists:member(C, Walls) of
        true -> wall;
        false -> trench
    end.
