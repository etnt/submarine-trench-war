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

-export([default/0, by_id/1, maps/0, to_json/1, tile_at/2, dims/1, spawns/1, legend/0]).
-export([current_at/2, turbulence_at/2, clear_mine/2, collapse/2]).
-export([data_nodes/1, extraction/1, open_tiles/1, connected/1]).

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

%% @doc The default map used when a room does not pick one.
-spec default() -> board().
default() ->
    by_id(<<"trench_alpha">>).

%% @doc Build a board by its map id. Unknown ids fall back to the default so
%% a stale or bad selection never crashes a game.
-spec by_id(binary()) -> board().
by_id(<<"trench_beta">>) -> build_beta();
by_id(_) -> build_alpha().

%% @doc The catalogue of selectable maps: `{id, human name}` pairs the lobby
%% offers to the host. Keep in sync with `by_id/1`.
-spec maps() -> [map()].
maps() ->
    [#{<<"id">> => <<"trench_alpha">>, <<"name">> => <<"Trench Alpha">>},
     #{<<"id">> => <<"trench_beta">>, <<"name">> => <<"Trench Bravo">>}].

%% Trench Alpha: a narrow trench network with vertical forks, four corner
%% spawns, scattered data nodes, a top-centre extraction zone, and a couple
%% of mines and thermal vents.
build_alpha() ->
    assemble(#{
      walls => alpha_walls(),
      spawns => [{2, 2}, {17, 2}, {2, 9}, {17, 9}],
      data_nodes => [{3, 5}, {8, 8}, {12, 3}, {16, 6}],
      extraction => {10, 1},
      mines => [{6, 3}, {13, 9}],
      vents => [{9, 7}, {11, 3}],
      %% Currents drift a submarine after each register resolves. Placed on
      %% open trench so they never point a sub straight into a wall gap.
      currents => #{{7, 2} => {e, 1}, {8, 2} => {e, 1}, {9, 2} => {e, 1},
                    {12, 9} => {n, 1}, {12, 8} => {n, 1}},
      %% Turbulence spins a submarine 90 degrees clockwise on entry.
      turbulence => [{8, 6}]}).

%% Trench Bravo: horizontal ledges instead of vertical forks, so the fleet
%% weaves top-right then bottom-left through the two gaps. Same four corner
%% spawns and top-row extraction patrol.
build_beta() ->
    assemble(#{
      walls => beta_walls(),
      spawns => [{2, 2}, {17, 2}, {2, 9}, {17, 9}],
      data_nodes => [{5, 5}, {14, 3}, {9, 9}, {16, 8}],
      extraction => {10, 1},
      mines => [{8, 3}, {12, 8}],
      vents => [{4, 6}, {15, 5}],
      currents => #{{2, 5} => {e, 1}, {3, 5} => {e, 1}, {16, 6} => {w, 1}},
      turbulence => [{10, 6}]}).

%% Vertical wall segments alternately attached to the top and bottom border,
%% each leaving a gap at the opposite end so the corridors weave but stay
%% fully connected (the test suite flood-fills to prove it).
alpha_walls() ->
    lists:usort(
      seg_v(5, 1, 8) ++      %% attached to top, gap at the bottom
      seg_v(10, 3, 10) ++    %% attached to bottom, gap at the top
      seg_v(14, 1, 8)).      %% attached to top, gap at the bottom

%% Horizontal ledges: one hugging the left with a gap on the right, one
%% hugging the right with a gap on the left, forming an S-shaped route.
beta_walls() ->
    lists:usort(
      seg_h(4, 1, 13) ++     %% gap on the right (x=14..18)
      seg_h(7, 6, 18)).      %% gap on the left  (x=1..5)

seg_v(X, Y1, Y2) -> [{X, Y} || Y <- lists:seq(Y1, Y2)].
seg_h(Y, X1, X2) -> [{X, Y} || X <- lists:seq(X1, X2)].

%% Assemble a board map from an authoring spec.
assemble(#{walls := Walls, spawns := Spawns, data_nodes := DataNodes,
           extraction := Extraction, mines := Mines, vents := Vents,
           currents := Currents, turbulence := Turbulence}) ->
    Tiles = build_tiles(Walls, Spawns, DataNodes, Extraction, Mines, Vents),
    #{width => ?W,
      height => ?H,
      tiles => Tiles,
      spawns => Spawns,
      data_nodes => DataNodes,
      extraction => Extraction,
      currents => Currents,
      turbulence => Turbulence}.

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

%% @doc Cave a tile in: turn it into wall and strip any current/turbulence it
%% carried. Used by dynamic map (collapse) events. Callers are responsible for
%% checking `connected/1` first so a collapse never traps a submarine.
-spec collapse(board(), coord()) -> board().
collapse(Board, Coord) ->
    Tiles = maps:get(tiles, Board),
    Currents = maps:get(currents, Board, #{}),
    Turb = maps:get(turbulence, Board, []),
    Board#{tiles => maps:put(Coord, wall, Tiles),
           currents => maps:remove(Coord, Currents),
           turbulence => lists:delete(Coord, Turb)}.

%% @doc Every passable (non-wall) tile on the board.
-spec open_tiles(board()) -> [coord()].
open_tiles(Board) ->
    {W, H} = dims(Board),
    [{X, Y} || Y <- lists:seq(0, H - 1), X <- lists:seq(0, W - 1),
               tile_at(Board, {X, Y}) =/= wall].

%% @doc True when every open tile is reachable from every other open tile.
%% A flood-fill from one open tile must cover all of them. Used to guarantee
%% collapses never split the map or strand a submarine/objective.
-spec connected(board()) -> boolean().
connected(Board) ->
    case open_tiles(Board) of
        [] -> true;
        [Start | _] = Open ->
            Seen = flood(Board, [Start], sets:new()),
            lists:all(fun(C) -> sets:is_element(C, Seen) end, Open)
    end.

flood(_Board, [], Seen) ->
    Seen;
flood(Board, [C | Rest], Seen) ->
    case sets:is_element(C, Seen) orelse tile_at(Board, C) =:= wall of
        true -> flood(Board, Rest, Seen);
        false -> flood(Board, neighbours(C) ++ Rest, sets:add_element(C, Seen))
    end.

neighbours({X, Y}) ->
    [{X + 1, Y}, {X - 1, Y}, {X, Y + 1}, {X, Y - 1}].

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
