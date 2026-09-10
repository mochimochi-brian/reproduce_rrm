# Structural size of a GAP input, without producing the map.
#
# rrm_input_stats(sym, ur, urt, ss) prints machine-readable lines only:
#   RRM_STAT_SYM_ORDER, RRM_STAT_DEGREE, RRM_STAT_NEQ, RRM_STAT_NTS,
#   RRM_STAT_NVERT, RRM_STAT_NEDGE, RRM_STAT_EQ_VERTS, RRM_STAT_TS_EDGES
#
# The counts are exact and independent of the producer: an EQ contributes
# Index(sym, ur[i]) vertices and a TS contributes Index(sym, urt[i]) edges,
# which is the length of the right transversal each producer enumerates.
# RRM_STAT_TS_EDGES is the per-TS expansion, i.e. the quantity the parallel
# driver's TS-count split does *not* balance.
#
# Used by tools/rrm_bench.py; also usable on its own, e.g.
#   gap -b -q -r -m 2g <<'EOF'
#   Read("tools/rrm_input_stats.g");
#   Read("data/Au5Ag_AFIR.g");
#   rrm_input_stats(symc, ur, urt, ss);
#   QUIT;
#   EOF

rrm_input_stats:=function(sym, ur, urt, ss)
	local nvert, nedge, counts, i, k, wrapped;

	# GAP breaks Print output at the terminal width, which would split the
	# per-TS lists across lines. Keep one record per line.
	wrapped:=PrintFormattingStatus("*stdout*");
	SetPrintFormattingStatus("*stdout*", false);

	Print("RRM_STAT_SYM_ORDER=", Size(sym), "\n");
	Print("RRM_STAT_DEGREE=", LargestMovedPoint(sym), "\n");
	Print("RRM_STAT_NEQ=", Length(ur), "\n");
	Print("RRM_STAT_NTS=", Length(ss), "\n");

	nvert:=0;
	counts:=[];
	for i in [1..Length(ur)] do
		k:=Index(sym, ur[i]);
		nvert:=nvert+k;
		counts[i]:=k;
	od;
	Print("RRM_STAT_NVERT=", nvert, "\n");
	Print("RRM_STAT_EQ_VERTS=");
	for i in [1..Length(counts)] do
		if i > 1 then Print(","); fi;
		Print(counts[i]);
	od;
	Print("\n");

	nedge:=0;
	counts:=[];
	for i in [1..Length(ss)] do
		k:=Index(sym, urt[i]);
		nedge:=nedge+k;
		counts[i]:=k;
	od;
	Print("RRM_STAT_NEDGE=", nedge, "\n");
	Print("RRM_STAT_TS_EDGES=");
	for i in [1..Length(counts)] do
		if i > 1 then Print(","); fi;
		Print(counts[i]);
	od;
	Print("\n");

	SetPrintFormattingStatus("*stdout*", wrapped);
	return;
end;;
