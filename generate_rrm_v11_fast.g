# Faster generate_rrm for generate_rrm_v11.g (same API; Au5Ag dat bytes match).
# Not a new Teramoto version: v11 stays the original script.
# Sequential: vertex id is offset[eq] + hash lookup of
# CanonicalRightCosetElement(ur[eq], g) (SparseHashTable + SparseIntKey),
# matching v11's Position(vertices, [eq, CanonicalRightCosetElement(...)])
# because vertices are appended in RightTransversal order. Edges are written with
# OutputTextFile inside the TS loop; the full edge list is not kept. Same-EQ
# Pechukas uses a cached RightTransversal. A failed coset lookup prints an
# error and FORCE_QUIT_GAP(1) (v11 would Print the string fail into the dat
# file and still exit 0). GAP's Error() returns under -T, so it is not a
# batch stop. A Pechukas violation also FORCE_QUIT_GAP(1) before writing dat
# files. Set RRM_CONTINUE_ON_PECHUKAS=1 (or GAP variable
# RRM_CONTINUE_ON_PECHUKAS:=true) to restore v11 print-and-continue.
# Optional workers: generate_rrm_vertices and generate_rrm_edge_shard are
# called by generate_rrm_v11_parallel.sh. Sequential generate_rrm is unchanged.
#
# vfile : file to save vertex information
# efile : file to save edge information
# sym : sym_Omega
# ur, urt : list of U(r_R)s and U(r_T)s
# ss : list of [[i,s1],[j,s2]] (i, j: indices of equilibrium structures, s1 and s2 are permutation from the equilibrium structures)
# labels : vertex (edge) label is attached if true and is not otherwise

RrmNewCosetIndex:=function(sym)
	local h;
	h:=SparseIntKey(sym, One(sym));
	if h=fail then
		Print("Error, no permutation hash key for vertex index\n");
		FORCE_QUIT_GAP(1);
	fi;
	return SparseHashTable(h);
end;;

RrmVertexIndex:=function(offset, idx, ur, eq, g)
	local pos;
	pos:=LookupDictionary(idx[eq], CanonicalRightCosetElement(ur[eq], g));
	if pos=fail then
		# Error() returns under gap -T; FORCE_QUIT_GAP is the batch stop.
		Print("Error, vertex lookup failed for EQ",eq-1,"\n");
		FORCE_QUIT_GAP(1);
	fi;
	return offset[eq]+pos;
end;;

if not IsBound(RRM_CONTINUE_ON_PECHUKAS) then
	RRM_CONTINUE_ON_PECHUKAS:=false;
fi;

RrmContinueOnPechukas:=function()
	local v;
	if RRM_CONTINUE_ON_PECHUKAS=true or RRM_CONTINUE_ON_PECHUKAS=1 then
		return true;
	fi;
	if IsBound(GAPInfo.SystemEnvironment) and
		IsBound(GAPInfo.SystemEnvironment.RRM_CONTINUE_ON_PECHUKAS) then
		v:=GAPInfo.SystemEnvironment.RRM_CONTINUE_ON_PECHUKAS;
		return v="1" or LowercaseString(v)="true" or LowercaseString(v)="yes";
	fi;
	return false;
end;;

RrmOnPechukasViolation:=function()
	if RrmContinueOnPechukas() then
		return;
	fi;
	Print("Error, Pechukas theorem violated; refusing to write dat files\n");
	FORCE_QUIT_GAP(1);
end;;

RrmBuildTransversals:=function(sym, ur)
	local rt, offset, nvert, idx, i, j, ht;
	rt:=[];
	offset:=[];
	idx:=[];
	nvert:=0;
	for i in [1..Length(ur)] do
		rt[i]:=RightTransversal(sym,ur[i]);
		ht:=RrmNewCosetIndex(sym);
		for j in [1..Length(rt[i])] do
			AddDictionary(ht, CanonicalRightCosetElement(ur[i], rt[i][j]), j);
		od;
		idx[i]:=ht;
		offset[i]:=nvert;
		nvert:=nvert+Length(rt[i]);
	od;
	return rec(rt:=rt, offset:=offset, nvert:=nvert, idx:=idx);
end;;

RrmCheckPechukas:=function(sym, ur, urt, ss, org_eq, org_ts, rt)
	local homByEq, i, eq, actionHom, permGroup, pos1, pos2, stabPerm, stabEQs;
	homByEq:=[];
	# check if GRRM graph is consistent with the required symmetry.
	for i in [1..Length(ss)] do
		# In this case, the reactant and product are permutation isomers.
		if ss[i][1][1] = ss[i][2][1] then
			eq:=ss[i][1][1];
			if not IsBound(homByEq[eq]) then
				homByEq[eq]:=ActionHomomorphism(sym,rt[eq],OnRight,"surjective");
			fi;
			actionHom:=homByEq[eq];
			permGroup:=Image(actionHom);
			pos1:=PositionCanonical(rt[eq],ss[i][1][2]^-1);
			pos2:=PositionCanonical(rt[eq],ss[i][2][2]^-1);
			if pos1=fail or pos2=fail then
				Print("Error, Pechukas coset lookup failed for TS",i-1,"\n");
				FORCE_QUIT_GAP(1);
			fi;
			stabPerm:=Stabilizer(permGroup,Set([pos1,pos2]),OnSets);
			stabEQs:=PreImage(actionHom,stabPerm);
			if not IsSubgroup(stabEQs,urt[i]) then
				Assert(0,false,"Violation of Pechukus theorem: \n");
	        		if org_ts[i] = i then
					Print("TS",i-1,":\n");
				else
					Print("TS",i-1,"*:\n");
				fi;

				Print("the reactant and product are permutation isomers\n");
                        	if org_eq[ss[i][1][1]]=ss[i][1][1] then
					Print("EQ",org_eq[ss[i][1][1]]-1,"\n");
				else
					Print("EQ",org_eq[ss[i][1][1]]-1,"*\n");
				fi;

				Print("in what follows, minus 1 to convert to the atom labels\n");
				Print("U(r) (for reactant):\n");
				Print(ur[ss[i][1][1]],"\n");
				Print("U(r) (for product):\n");
				Print(ur[ss[i][2][1]],"\n");
				Print("stabEQs:\n");
				Print(stabEQs,"\n");
				Print("U(r) (for transition state):\n");
				Print(urt[i],"\n");
				RrmOnPechukasViolation();
			fi;
		# In this case, the reactant and product are not.
		else
			if not IsSubgroup(ConjugateGroup(ur[ss[i][1][1]],ss[i][1][2]),urt[i]) or
				not IsSubgroup(ConjugateGroup(ur[ss[i][2][1]],ss[i][2][2]),urt[i]) then

				Assert(0,false,"Violation of Pechukus theorem: \n");
	        		if org_ts[i] = i then
					Print("TS",i-1,":\n");
				else
					Print("TS",i-1,"*:\n");
				fi;

				Print("reactant:\n");
                        	if org_eq[ss[i][1][1]]=ss[i][1][1] then
					Print("EQ",org_eq[ss[i][1][1]]-1,"\n");
				else
					Print("EQ",org_eq[ss[i][1][1]]-1,"*\n");
				fi;

				Print("product:\n");
                        	if org_eq[ss[i][2][1]]=ss[i][2][1] then
					Print("EQ",org_eq[ss[i][2][1]]-1,"\n");
				else
					Print("EQ",org_eq[ss[i][2][1]]-1,"*\n");
				fi;

				Print("in what follows, minus 1 to convert to the atom labels\n");
				Print("U(r) (for reactant):\n");
				Print(ConjugateGroup(ur[ss[i][1][1]],ss[i][1][2]),"\n");
				Print("U(r) (for product):\n");
				Print(ConjugateGroup(ur[ss[i][2][1]],ss[i][2][2]),"\n");
				Print("U(r) (for transition state):\n");
				Print(urt[i],"\n");
				RrmOnPechukasViolation();
			fi;
		fi;
	od;
end;;

RrmWriteVertices:=function(vfile, ur, org_eq, rt, vlabel)
	local vstream, vid, ind, i, rturi, canon;
	vstream:=OutputTextFile(vfile,false);
	if vstream=fail then
		Print("Error, cannot write ",vfile,"\n");
		FORCE_QUIT_GAP(1);
	fi;
	SetPrintFormattingStatus(vstream,false);
	vid:=0;
	ind:=0;
	for i in [1..Length(ur)] do
		for rturi in rt[i] do
			vid:=vid+1;
			if ind <> i then
				if ind <> 0 then
					AppendTo(vstream,"}\n");
				fi;

				if org_eq[i]=i then
					AppendTo(vstream,"subgraph cluster_",i-1," { label=\"",org_eq[i]-1,"\";\n");
				else
					AppendTo(vstream,"subgraph cluster_",i-1," { label=\"",org_eq[i]-1,"*\";\n");
				fi;

				AppendTo(vstream,"fontsize=\"30pt\"\n");
				ind:=i;
			fi;

			canon:=CanonicalRightCosetElement(ur[i],rturi);
			if vlabel then
				if org_eq[i]=i then
					AppendTo(vstream,vid,"[label=\"",org_eq[i]-1," ",canon^-1,"\"]\n");
				else
					AppendTo(vstream,vid,"[label=\"",org_eq[i]-1,"* ",canon^-1,"\"]\n");
				fi;
			else
				AppendTo(vstream,vid,"\n");
			fi;
		od;
	od;
	AppendTo(vstream,"}\n");
	CloseStream(vstream);
end;;

RrmWriteEdges:=function(efile, sym, urt, ss, org_ts, offset, idx, ur, elabel, lo, hi)
	local estream, i, rturti, id1, id2, canon;
	estream:=OutputTextFile(efile,false);
	if estream=fail then
		Print("Error, cannot write ",efile,"\n");
		FORCE_QUIT_GAP(1);
	fi;
	SetPrintFormattingStatus(estream,false);
	if lo<=hi then
		if lo<1 or hi>Length(ss) then
			Print("Error, TS slice out of range\n");
			FORCE_QUIT_GAP(1);
		fi;
		for i in [lo..hi] do
			for rturti in RightTransversal(sym,urt[i]) do
				id1:=RrmVertexIndex(offset,idx,ur,ss[i][1][1],ss[i][1][2]^-1*rturti);
				id2:=RrmVertexIndex(offset,idx,ur,ss[i][2][1],ss[i][2][2]^-1*rturti);
				canon:=CanonicalRightCosetElement(urt[i],rturti);
				if elabel then
					if org_ts[i]=i then
						AppendTo(estream,id1,"--",id2,"[label=\"",org_ts[i]-1," ",canon^-1,"\"]\n");
					else
						AppendTo(estream,id1,"--",id2,"[label=\"",org_ts[i]-1,"* ",canon^-1,"\"]\n");
					fi;
				else
					AppendTo(estream,id1,"--",id2,"\n");
				fi;
			od;
		od;
	fi;
	CloseStream(estream);
end;;

generate_rrm:=function(vfile, efile, sym, ur, urt, ss, org_eq, org_ts, labels...)
	local vlabel, elabel, built;

	if Length(labels)=0 then
		vlabel:=true;
		elabel:=true;
	elif Length(labels)=1 then
		vlabel:=labels[1];
		elabel:=true;
	else
		vlabel:=labels[1];
		elabel:=labels[2];
	fi;

	built:=RrmBuildTransversals(sym, ur);
	RrmCheckPechukas(sym, ur, urt, ss, org_eq, org_ts, built.rt);
	RrmWriteVertices(vfile, ur, org_eq, built.rt, vlabel);
	RrmWriteEdges(efile, sym, urt, ss, org_ts, built.offset, built.idx, ur, elabel, 1, Length(ss));
	return;
end;;

generate_rrm_vertices:=function(vfile, sym, ur, urt, ss, org_eq, org_ts, labels...)
	local vlabel, built;
	if Length(labels)=0 then
		vlabel:=true;
	else
		vlabel:=labels[1];
	fi;
	built:=RrmBuildTransversals(sym, ur);
	RrmCheckPechukas(sym, ur, urt, ss, org_eq, org_ts, built.rt);
	RrmWriteVertices(vfile, ur, org_eq, built.rt, vlabel);
	Print("RRM_NVERT=", built.nvert, "\n");
	Print("RRM_NTS=", Length(ss), "\n");
	return built.nvert;
end;;

# Workers recompute RrmBuildTransversals independently. Edge ids match the
# master's vertex file only if RightTransversal(sym, ur[i]) enumerates the
# same order in every process (GAP -r, same Reads, same first call).
# RRM_NVERT checks counts, not permutation of rt[i]. org_eq is unused here
# and kept for generate_rrm signature parity.
generate_rrm_edge_shard:=function(efile, lo, hi, sym, ur, urt, ss, org_eq, org_ts, labels...)
	local elabel, built;
	elabel:=true;
	if Length(labels)>=1 then
		elabel:=labels[1];
	fi;
	built:=RrmBuildTransversals(sym, ur);
	RrmWriteEdges(efile, sym, urt, ss, org_ts, built.offset, built.idx, ur, elabel, lo, hi);
	Print("RRM_NVERT=", built.nvert, "\n");
	return built.nvert;
end;;

