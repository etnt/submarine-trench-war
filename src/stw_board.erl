%%%-------------------------------------------------------------------
%% @doc Trench board model and the first static map.
%%
%% A board is a rectangular grid of tiles. Each tile has a `kind`:
%%
%%   wall        impassable rock
%%   trench      open water (submarines move through this)
%%   spawn       open water that also seeds a starting position
%%   data_node   a black-box data node to collect
%%   extraction  an extraction zone (surface here to score)
%%   mine        a hazard tile
%%   vent        a thermal vent
%%
%% For movement purposes every non-wall kind is passable. Depth is a
%% property of a submarine (shallow/deep), not of the tile, so the board
%% is a single 2D grid; depth-specific hazard rules arrive in later phases.
%%
%% The board is authored in code (not ASCII) so the dimensions are always
%% rectangular by construction; connectivity is verified by the test suite.
%% @end
%%%-------------------------------------------------------------------
-module(stw_board).

-export([default/0, to_json/1, tile_at/2, dims/1, spawns/1, legend/0]).
-export([current_at/2, turbulence_at/2, clear_mine/2]).
-export([data_nodes/1, extraction/1]).

-define(W, 20).
-define(H, 12).

-type coord() :: {non_neg_integer(), non_neg_integer()}.
-type kind() :: wall | trench | spawn | data_node | extraction | mine | vent.
-type dir() :: n | e | s | w.
-type board() :: #{
    width := pos_integer(),
    height := pos_integer(),
    tiles := #{coord() => kind()},
    spawns := [coord()],
    data_nodes := [coord()],
    extraction := coord(),
    currents := #{coord() => {dir(), pos_integer()}},
    turbulence := [coord()]
}.

-export_type([board/0, coord/0, kind/0, dir/0]).

%% --- construction -----------------------------------------------------

%% @doc The first hand-designed map: a narrow trench network with forks,
%% four corner spawns, scattered data nodes, a top-centre extraction zone,
%% and a couple of mines and thermal vents.
-spec default() -> board().
default() ->
    Walls = wall_set(),
    Spawns = [{2, 2}, {17, 2}, {2, 9}, {17, 9}],
    DataNodes = [{3, 5}, {8, 8}, {12, 3}, {16, 6}],
    Extraction = {10, 1},
    Mines = [{6, 3}, {13, 9}],
    Vents = [{9, 7}, {11, 3}],
    Tiles = build_tiles(Walls, Spawns, DataNodes, Extraction, Mines, Vents),
    #{width => ?W,
      height => ?H,
      tiles => Tiles,
      spawns => Spawns,
      data_nodes => DataNodes,
      extraction => Extraction,
      %% Currents drift a submarine after each register resolves. Placed on
      %% open trench so they never point a sub straight into a wall gap.
      currents => #{{7, 2} => {e, 1}, {8, 2} => {e, 1}, {9, 2} => {e, 1},
                    {12, 9} => {n, 1}, {12, 8} => {n, 1}},
      %% Turbulence spins a submarine 90 degrees clockwise on entry.
      turbulence => [{8, 6}]}.

%% Interior wall segments creating the fork/serpentine feel. The vertical
%% walls alternately attach to the top and bottom border, each leaving a
%% two-tile gap at the opposite end, so the corridors weave but stay fully
%% connected (the test suite flood-fills to prove it).
wall_set() ->
    lists:usort(
      seg_v(5, 1, 8) ++      %% attached to top, gap at the bottom
      seg_v(10, 3, 10) ++    %% attached to bottom, gap at the top
      seg_v(14, 1, 8)).      %% attached to top, gap at the bottom

seg_v(X, Y1, Y2) -> [{X, Y} || Y <- lists:seq(Y1, Y2)].

build_tiles(Walls, Spawns, DataNodes, Extraction, Mines, Vents) ->
    WallSet = maps:from_keys(Walls, wall),
    SpawnSet = maps:from_keys(Spawns, spawn),
    NodeSet = maps:from_keys(DataNodes, data_node),
    MineSet = maps:from_keys(Mines, mine),
    VentSet = maps:from_keys(Vents, vent),
    Feature = fun(C) ->
        classify(C, WallSet, SpawnSet, NodeSet, MineSet, VentSet, Extraction)
    end,
    maps:from_list(
      [{{X, Y}, Feature({X, Y})}
       || Y <- lists:seq(0, ?H - 1), X <- lists:seq(0, ?W - 1)]).

classify({X, Y}, WallSet, SpawnSet, NodeSet, MineSet, VentSet, Extraction) ->
    Border = (X =:= 0) orelse (Y =:= 0) orelse (X =:= ?W - 1) orelse (Y =:= ?H - 1),
    C = {X, Y},
    if
        Border -> wall;
        is_map_key(C, WallSet) -> wall;
        is_map_key(C, SpawnSet) -> spawn;
        C =:= Extraction -> extraction;
        is_map_key(C, NodeSet) -> data_node;
        is_map_key(C, MineSet) -> mine;
        is_map_key(C, VentSet) -> vent;
        true -> trench
    end.

%% --- queries ----------------------------------------------------------

-spec tile_at(board(), coord()) -> kind().
tile_at(Board, Coord) ->
    maps:get(Coord, maps:get(tiles, Board), wall).

%% @doc Remove a triggered mine, turning it back into open trench. A
%% non-mine tile is returned unchanged.
-spec clear_mine(board(), coord()) -> board().
clear_mine(Board, Coord) ->
    Tiles = maps:get(tiles, Board),
    case maps:get(Coord, Tiles, wall) of
        mine -> Board#{tiles => maps:put(Coord, trench, Tiles)};
        _ -> Board
    end.

-spec dims(board()) -> {pos_integer(), pos_integer()}.
dims(Board) ->
    {maps:get(width, Board), maps:get(height, Board)}.

-spec spawns(board()) -> [coord()].
spawns(Board) ->
    maps:get(spawns, Board).

%% @doc The authored data-node positions for this map.
-spec data_nodes(board()) -> [coord()].
data_nodes(Board) ->
    maps:get(data_nodes, Board, []).

%% @doc The authored (initial) extraction-zone position for this map.
-spec extraction(board()) -> coord().
extraction(Board) ->
    maps:get(extraction, Board).

%% @doc The current on a tile, or `none`. A current is `{Direction, Strength}`.
-spec current_at(board(), coord()) -> {dir(), pos_integer()} | none.
current_at(Board, Coord) ->
    maps:get(Coord, maps:get(currents, Board, #{}), none).

-spec turbulence_at(board(), coord()) -> boolean().
turbulence_at(Board, Coord) ->
    lists:member(Coord, maps:get(turbulence, Board, [])).

%% --- serialization ----------------------------------------------------

%% @doc Serialize the whole board for the client as rows of single-char
%% tiles plus a legend mapping each char to a kind name. Sending the full
%% board is fine until fog of war (Phase 6) trims it to visible tiles.
-spec to_json(board()) -> map().
to_json(Board) ->
    {W, H} = dims(Board),
    Grid = [row_bin(Y, Board, W) || Y <- lists:seq(0, H - 1)],
    #{<<"width">> => W,
      <<"height">> => H,
      <<"grid">> => Grid,
      <<"legend">> => legend(),
      <<"currents">> => currents_json(Board),
      <<"turbulence">> => [xy(C) || C <- maps:get(turbulence, Board, [])]}.

currents_json(Board) ->
    [begin
         {X, Y} = C,
         #{<<"x">> => X, <<"y">> => Y,
           <<"dir">> => dir_bin(Dir), <<"strength">> => Str}
     end || {C, {Dir, Str}} <- maps:to_list(maps:get(currents, Board, #{}))].

xy({X, Y}) -> #{<<"x">> => X, <<"y">> => Y}.

dir_bin(n) -> <<"N">>;
dir_bin(e) -> <<"E">>;
dir_bin(s) -> <<"S">>;
dir_bin(w) -> <<"W">>.

row_bin(Y, Board, W) ->
    list_to_binary([kind_char(tile_at(Board, {X, Y})) || X <- lists:seq(0, W - 1)]).

kind_char(wall) -> $#;
kind_char(trench) -> $.;
kind_char(spawn) -> $S;
%% Data nodes and the extraction zone are hidden from the static grid: they
%% are revealed dynamically per player (fog of war) via game_state.
kind_char(data_node) -> $.;
kind_char(extraction) -> $.;
kind_char(mine) -> $M;
kind_char(vent) -> $V.

-spec legend() -> map().
legend() ->
    #{<<"#">> => <<"wall">>,
      <<".">> => <<"trench">>,
      <<"S">> => <<"spawn">>,
      <<"D">> => <<"data_node">>,
      <<"X">> => <<"extraction">>,
      <<"M">> => <<"mine">>,
      <<"V">> => <<"vent">>}.
