Require Import riscv.Utility.Monads. Require Import riscv.Utility.MonadNotations.
Require Import coqutil.Macros.unique.
Require Import compiler.FlatImp.
Require Import Coq.Lists.List.
Import ListNotations.
Require Import Coq.ZArith.ZArith.
Require Import riscv.Spec.Machine.
Require Import riscv.Spec.Decode.
Require Import riscv.Spec.PseudoInstructions.
Require Import riscv.Platform.RiscvMachine.
Require Import riscv.Spec.Execute.
Require Import riscv.Platform.Run.
Require Import riscv.Platform.Memory.
Require Import riscv.Utility.PowerFunc.
Require Import riscv.Utility.ListLib.
Require Import coqutil.Decidable.
Require Import Coq.Program.Tactics.
Require Import Coq.Bool.Bool.
Require Import riscv.Utility.InstructionCoercions.
Require Import riscv.Spec.Primitives.
Require Import coqutil.Z.Lia.
Require Import riscv.Utility.div_mod_to_quot_rem.
Require Import compiler.util.Misc.
Require Import riscv.Utility.Utility.
Require Import coqutil.Z.BitOps.
Require Import compiler.util.Common.
Require Import riscv.Utility.Utility.
Require Import riscv.Utility.MkMachineWidth.
Require Import riscv.Utility.runsToNonDet.
Require Import compiler.FlatToRiscvDef.
Require Import compiler.GoFlatToRiscv.
Require Import compiler.EmitsValid.
Require Import compiler.SeparationLogic.
Require Import bedrock2.Scalars.
Require Import compiler.Simp.
Require Import compiler.SimplWordExpr.
Require Import bedrock2.ptsto_bytes.
Require Import compiler.RiscvWordProperties.
Require Import compiler.eqexact.
Require Import compiler.on_hyp_containing.
Require Import compiler.PushPullMod.
Require coqutil.Map.Empty_set_keyed_map.
Require Import coqutil.Z.bitblast.
Require Import riscv.Utility.prove_Zeq_bitwise.
Require Import compiler.RunInstruction.
Require Import compiler.DivisibleBy4.

Local Open Scope ilist_scope.
Local Open Scope Z_scope.

Set Implicit Arguments.

Module Import FlatToRiscv.
  Export FlatToRiscvDef.FlatToRiscvDef.

  Class parameters := {
    def_params :> FlatToRiscvDef.parameters;

    locals :> map.map Register word;
    mem :> map.map word byte;

    M: Type -> Type;
    MM :> Monad M;
    RVM :> RiscvProgram M word;
    PRParams :> PrimitivesParams M (RiscvMachine Register actname);

    ext_spec : list (mem * actname * list word * (mem * list word)) ->
               mem -> actname -> list word -> (mem -> list word -> Prop) -> Prop;

    (* An abstract predicate on the low-level state, which can be chosen by authors of
       extensions. The compiler will ensure that this guarantee holds before each external
       call. *)
    ext_guarantee: RiscvMachine Register actname -> Prop;
  }.

  Instance Semantics_params{p: parameters}: Semantics.parameters := {|
    Semantics.syntax := FlatToRiscvDef.mk_Syntax_params _;
    Semantics.ext_spec := ext_spec;
    Semantics.funname_eqb := Empty_set_rect _;
    Semantics.funname_env := Empty_set_keyed_map.map;
  |}.

  Class assumptions{p: parameters} := {
    word_riscv_ok :> word.riscv_ok (@word W);
    locals_ok :> map.ok locals;
    mem_ok :> map.ok mem;
    actname_eq_dec :> DecidableEq actname;
    PR :> Primitives PRParams;

    (* For authors of extensions, a freely choosable ext_guarantee sounds too good to be true!
       And indeed, there are two restrictions:
       The first restriction is that ext_guarantee needs to be preservable for the compiler: *)
    ext_guarantee_preservable: forall (m1 m2: RiscvMachine Register actname),
        ext_guarantee m1 ->
        map.same_domain m1.(getMem) m2.(getMem) ->
        m1.(getLog) = m2.(getLog) ->
        ext_guarantee m2;

    (* And the second restriction is part of the correctness requirement for compilation of
       external calls: Every compiled external call has to preserve ext_guarantee *)
    compile_ext_call_correct: forall (initialL: RiscvMachine Register actname) action postH newPc insts
        (argvars resvars: list Register) initialMH R,
      insts = compile_ext_call resvars action argvars ->
      newPc = word.add initialL.(getPc) (word.mul (word.of_Z 4) (word.of_Z (Zlength insts))) ->
      Forall valid_register argvars ->
      Forall valid_register resvars ->
      (program initialL.(getPc) insts * eq initialMH * R)%sep initialL.(getMem) ->
      initialL.(getNextPc) = word.add initialL.(getPc) (word.of_Z 4) ->
      ext_guarantee initialL ->
      exec map.empty (SInteract resvars action argvars)
           initialL.(getLog) initialMH initialL.(getRegs) postH ->
      runsTo (mcomp_sat (run1 iset)) initialL
             (fun finalL =>
                  (* external calls can't modify the memory for now *)
                  postH finalL.(getLog) initialMH finalL.(getRegs) /\
                  finalL.(getPc) = newPc /\
                  finalL.(getNextPc) = add newPc (ZToReg 4) /\
                  (program initialL.(getPc) insts * eq initialMH * R)%sep finalL.(getMem) /\
                  ext_guarantee finalL);
  }.

End FlatToRiscv.

Local Unset Universe Polymorphism. (* for Add Ring *)

Section FlatToRiscv1.
  Context {p: unique! FlatToRiscv.parameters}.
  Context {h: unique! FlatToRiscv.assumptions}.

  Notation var := Z (only parsing).

  Definition trace := list (LogItem actname).

  Local Notation RiscvMachineL := (RiscvMachine Register actname).

  Add Ring wring : (word.ring_theory (word := word))
      (preprocess [autorewrite with rew_word_morphism],
       morphism (word.ring_morph (word := word)),
       constants [word_cst]).

  Lemma reduce_eq_to_sub_and_lt: forall (y z: word),
      word.eqb y z = word.ltu (word.sub y z) (word.of_Z 1).
  Proof.
    intros.
    rewrite word.unsigned_eqb.
    rewrite word.unsigned_ltu.
    rewrite word.unsigned_sub.
    rewrite word.unsigned_of_Z.
    pose proof (word.unsigned_range y) as Ry.
    pose proof (word.unsigned_range z) as Rz.
    remember (word.unsigned y) as a; clear Heqa.
    remember (word.unsigned z) as b; clear Heqb.
    assert (1 < 2 ^ width). {
      destruct width_cases as [E | E]; rewrite E; reflexivity.
    }
    destruct (Z.eqb_spec a b).
    - subst a. rewrite Z.sub_diag. unfold word.wrap. rewrite Z.mod_0_l by blia.
      rewrite Z.mod_small; [reflexivity|blia].
    - unfold word.wrap. rewrite (Z.mod_small 1) by blia.
      destruct (Z.ltb_spec ((a - b) mod 2 ^ width) 1); [exfalso|reflexivity].
      pose proof (Z.mod_pos_bound (a - b) (2 ^ width)).
      assert ((a - b) mod 2 ^ width = 0) as A by blia.
      apply Znumtheory.Zmod_divide in A; [|blia].
      unfold Z.divide in A.
      destruct A as [k A].
      clear -Ry Rz A n.
      assert (k <> 0); Lia.nia.
  Qed.

  (* Set Printing Projections.
     Prints some implicit arguments it shouldn't print :(
     COQBUG https://github.com/coq/coq/issues/9814 *)

  Arguments Z.mul: simpl never.
  Arguments Z.add: simpl never.
  Arguments Z.of_nat: simpl never.
  Arguments run1: simpl never.

  Ltac simulate''_step :=
    first (* not everyone wants these: *)
          [ eapply go_loadByte       ; [sidecondition..|]
          | eapply go_storeByte      ; [sidecondition..|]
          | eapply go_loadHalf       ; [sidecondition..|]
          | eapply go_storeHalf      ; [sidecondition..|]
          | eapply go_loadWord       ; [sidecondition..|]
          | eapply go_storeWord      ; [sidecondition..|]
          | eapply go_loadDouble     ; [sidecondition..|]
          | eapply go_storeDouble    ; [sidecondition..|]
          (* reuse defaults which everyone wants: *)
          | simulate_step
          | simpl_modu4_0 ].

  Ltac simulate'' := repeat simulate''_step.

  Lemma go_load: forall sz x a (addr v: word) initialL post f,
      valid_register x ->
      valid_register a ->
      map.get initialL.(getRegs) a = Some addr ->
      Memory.load sz (getMem initialL) addr = Some v ->
      mcomp_sat (f tt)
                (withRegs (map.put initialL.(getRegs) x v) initialL) post ->
      mcomp_sat (Bind (execute (compile_load sz x a 0)) f) initialL post.
  Proof.
    unfold compile_load, Memory.load, Memory.load_Z, Memory.bytes_per.
    destruct width_cases as [E | E];
      (* note: "rewrite E" does not work because "width" also appears in the type of "word",
         but we don't need to rewrite in the type of word, only in the type of the tuple,
         which works if we do it before intro'ing it *)
      (destruct (width =? 32) eqn: E'; [apply Z.eqb_eq in E' | apply Z.eqb_neq in E']);
      try congruence;
      clear E';
      [set (nBytes := 4%nat) | set (nBytes := 8%nat)];
      replace (Z.to_nat ((width + 7) / 8)) with nBytes by (subst nBytes; rewrite E; reflexivity);
      subst nBytes;
      intros; destruct sz; try solve [
        unfold execute, ExecuteI.execute, ExecuteI64.execute, translate, DefaultRiscvState,
        Memory.load, Memory.load_Z in *;
        simp; simulate''; simpl; simpl_word_exprs word_ok;
          try eassumption].
  Qed.

  Lemma go_store: forall sz x a (addr v: word) initialL m' post f,
      valid_register x ->
      valid_register a ->
      map.get initialL.(getRegs) x = Some v ->
      map.get initialL.(getRegs) a = Some addr ->
      Memory.store sz (getMem initialL) addr v = Some m' ->
      mcomp_sat (f tt) (withMem m' initialL) post ->
      mcomp_sat (Bind (execute (compile_store sz a x 0)) f) initialL post.
  Proof.
    unfold compile_store, Memory.store, Memory.store_Z, Memory.bytes_per;
    destruct width_cases as [E | E];
      (* note: "rewrite E" does not work because "width" also appears in the type of "word",
         but we don't need to rewrite in the type of word, only in the type of the tuple,
         which works if we do it before intro'ing it *)
      (destruct (width =? 32) eqn: E'; [apply Z.eqb_eq in E' | apply Z.eqb_neq in E']);
      try congruence;
      clear E';
      [set (nBytes := 4%nat) | set (nBytes := 8%nat)];
      replace (Z.to_nat ((width + 7) / 8)) with nBytes by (subst nBytes; rewrite E; reflexivity);
      subst nBytes;
      intros; destruct sz; try solve [
        unfold execute, ExecuteI.execute, ExecuteI64.execute, translate, DefaultRiscvState,
        Memory.store, Memory.store_Z in *;
        simp; simulate''; simpl; simpl_word_exprs word_ok; eassumption].
  Qed.

  Lemma run_compile_load: forall sz: Syntax.access_size,
      run_Load_spec (@Memory.bytes_per width sz) (compile_load sz) id.
  Proof.
    intro sz. destruct sz; simpl.
    - refine run_Lbu.
    - refine run_Lhu.
    - destruct width_cases as [E | E]; rewrite E; simpl.
      + refine (run_Lw_unsigned E).
      + refine run_Lwu.
    - destruct width_cases as [E | E]; rewrite E; simpl.
      + refine (run_Lw_unsigned E).
      + refine run_Ld_unsigned.
  Qed.

  Lemma run_compile_store: forall sz: Syntax.access_size,
      run_Store_spec (@Memory.bytes_per width sz) (compile_store sz).
  Proof.
    intro sz. destruct sz; simpl.
    - refine run_Sb.
    - refine run_Sh.
    - refine run_Sw.
    - destruct width_cases as [E | E]; rewrite E; simpl.
      + refine run_Sw.
      + refine run_Sd.
  Qed.

  Definition runsTo: RiscvMachineL -> (RiscvMachineL -> Prop) -> Prop :=
    runsTo (mcomp_sat (run1 iset)).

  Lemma one_step: forall initialL P,
      mcomp_sat (run1 iset) initialL P ->
      runsTo initialL P.
  Proof.
    intros.
    eapply runsToStep; [eassumption|].
    intros.
    apply runsToDone. assumption.
  Qed.

  Ltac simpl_run1 :=
    cbv [run1 (*execState*) OStateNDOperations.put OStateNDOperations.get
         Return Bind State_Monad OStateND_Monad
         execute ExecuteI.execute ExecuteM.execute ExecuteI64.execute ExecuteM64.execute
         getRegs getPc getNextPc getMem getLog
         getPC setPC getRegister setRegister].

  Tactic Notation "log_solved" tactic(t) :=
    match goal with
    | |- ?G => let H := fresh in assert G as H by t; idtac "solved" G; exact H
    | |- ?G => idtac "did not solve" G
    end.

  Local Ltac solve_stmt_not_too_big :=
    lazymatch goal with
    | H: stmt_not_too_big _ |- stmt_not_too_big _ =>
        clear -H;
        unfold stmt_not_too_big in *;
        change (2 ^ 9)%Z with 512%Z in *;
        simpl stmt_size in H;
        repeat match goal with
               | s: stmt |- @stmt_size ?params _ < _ =>
                 (* PARAMRECORDS *)
                 unique pose proof (@stmt_size_nonneg params s)
               end;
        match goal with
        | |- ?SZ _ _ < _ => (* COQBUG https://github.com/coq/coq/issues/9268 *)
          change @stmt_size with SZ in *
        end;
        blia
    end.

  Ltac simpl_RiscvMachine_get_set := simpl in *. (* TODO is this enough? *)

  Ltac destruct_RiscvMachine_0 m :=
    let t := type of m in
    unify t RiscvMachine;
    let r := fresh m "_regs" in
    let p := fresh m "_pc" in
    let n := fresh m "_npc" in
    let e := fresh m "_eh" in
    let me := fresh m "_mem" in
    destruct m as [ [r p n e] me ];
    simpl_RiscvMachine_get_set.

  Ltac destruct_RiscvMachine m :=
    let t := type of m in
    unify t RiscvMachineL;
    let r := fresh m "_regs" in
    let p := fresh m "_pc" in
    let n := fresh m "_npc" in
    let me := fresh m "_mem" in
    let l := fresh m "_log" in
    destruct m as [r p n me l];
    simpl_RiscvMachine_get_set.

  Arguments Z.modulo : simpl never.

  Ltac solve_valid_registers :=
    match goal with
    | |- valid_registers _ => solve [simpl; auto]
    end.

  Lemma disjoint_putmany_preserves_store_bytes: forall n a vs (m1 m1' mq: mem),
      store_bytes n m1 a vs = Some m1' ->
      map.disjoint m1 mq ->
      store_bytes n (map.putmany m1 mq) a vs = Some (map.putmany m1' mq).
  Proof.
    intros.
    unfold store_bytes, load_bytes, unchecked_store_bytes in *. simp.
    erewrite map.getmany_of_tuple_in_disjoint_putmany by eassumption.
    f_equal.
    set (ks := (footprint a n)) in *.
    rename mq into m2.
    rewrite map.putmany_of_tuple_to_putmany.
    rewrite (map.putmany_of_tuple_to_putmany n m1 ks vs).
    apply map.disjoint_putmany_commutes.
    pose proof map.getmany_of_tuple_to_sub_domain as P.
    specialize P with (1 := E).
    apply map.sub_domain_value_indep with (vs2 := vs) in P.
    set (mp := (map.putmany_of_tuple ks vs map.empty)) in *.
    apply map.disjoint_comm.
    eapply map.sub_domain_disjoint; eassumption.
  Qed.

  Lemma store_bytes_preserves_footprint: forall n a v (m m': mem),
      Memory.store_bytes n m a v = Some m' ->
      map.same_domain m m'.
  Proof.
    intros. unfold store_bytes, load_bytes, unchecked_store_bytes in *. simp.
    eauto using map.putmany_of_tuple_preserves_domain.
  Qed.

  Ltac simpl_bools :=
    repeat match goal with
           | H : ?x = false |- _ =>
             progress rewrite H in *
           | H : ?x = true |- _ =>
             progress rewrite H in *
           | |- context [negb true] => progress unfold negb
           | |- context [negb false] => progress unfold negb
           | H : negb ?x = true |- _ =>
             let H' := fresh in
             assert (x = false) as H' by (eapply negb_true_iff; eauto);
             clear H
           | H : negb ?x = false |- _ =>
             let H' := fresh in
             assert (x = true) as H' by (eapply negb_false_iff; eauto);
             clear H
           end.

  Ltac prove_ext_guarantee :=
    eapply ext_guarantee_preservable; [eassumption | simpl | reflexivity ];
    (* eauto using the lemmas below doesn't work, why? *)
    first [ eapply map.same_domain_refl |
            eapply store_bytes_preserves_footprint; eassumption ].

  Ltac simulate'_step :=
    first (* lemmas introduced only in this file: *)
          [ eapply go_load  ; [sidecondition..|]
          | eapply go_store ; [sidecondition..|]
          | simulate_step
          | simpl_modu4_0 ].

  Ltac simulate' := repeat simulate'_step.

  Ltac run1det :=
    eapply runsTo_det_step;
    [ simulate';
      match goal with
      | |- ?mid = ?RHS =>
        (* simpl RHS because mid will be instantiated to it and turn up again in the next step *)
        is_evar mid; simpl; reflexivity
      | |- _ => fail 10000 "simulate' did not go through completely"
      end
    | ].

  (* seplog which knows that "program" is an array and how to deal with cons and append in
     that array, and how to make addresses match *)
  Ltac pseplog :=
    unfold program in *;
    repeat match goal with
           | H: _ ?m |- _ ?m => progress (simpl in * (* does array_cons *))
           | H: context [array _ _ ?addr1 ?content] |- context [array _ _ ?addr2 ?content] =>
             progress replace addr1 with addr2 in H by ring;
               ring_simplify addr2;
               ring_simplify addr2 in H
           (* just unprotected seprewrite will instantiate evars in undesired ways *)
           | |- context [ array ?PT ?SZ ?start (?xs ++ ?ys) ] =>
             seprewrite0 (array_append_DEPRECATED PT SZ xs ys start)
           | H: context [ array ?PT ?SZ ?start (?xs ++ ?ys) ] |- _ =>
             seprewrite0_in (array_append_DEPRECATED PT SZ xs ys start) H
           end;
    seplog.

  Ltac apply_post :=
    match goal with
    | H: ?post _ _ _ |- ?post _ _ _ =>
      eqexact H; f_equal; symmetry;
      (apply word.sru_ignores_hibits ||
       apply word.slu_ignores_hibits ||
       apply word.srs_ignores_hibits ||
       apply word.mulhuu_simpl ||
       apply word.divu0_simpl ||
       apply word.modu0_simpl)
    end.

  Ltac run1done :=
    apply runsToDone;
    simpl in *;
    eexists;
    repeat split;
    simpl_word_exprs (@word_ok (@W (@def_params p)));
    first
      [ solve [eauto]
      | solve_word_eq (@word_ok (@W (@def_params p)))
      | solve [pseplog]
      | prove_ext_guarantee
      | apply_post
      | idtac ].

  Arguments LittleEndian.combine: simpl never.

  Lemma iset_is_supported: supported_iset iset.
  Proof.
    unfold iset. destruct_one_match; constructor.
  Qed.

  Ltac substs :=
    repeat match goal with
           | x := _ |- _ => subst x
           | _: ?x = _ |- _ => subst x
           | _: _ = ?x |- _ => subst x
           end.

  Ltac match_apply_runsTo :=
    match goal with
    | R: runsTo ?m ?post |- runsToNonDet.runsTo _ ?m' ?post =>
      replace m' with m; [exact R|]
    end;
    cbv [withRegs withPc withNextPc withMem withLog];
    f_equal.

  Lemma compile_lit_correct_full: forall initialL post x v R,
      initialL.(getNextPc) = add initialL.(getPc) (ZToReg 4) ->
      let insts := compile_stmt (SLit x v) in
      let d := mul (ZToReg 4) (ZToReg (Zlength insts)) in
      (program initialL.(getPc) insts * R)%sep initialL.(getMem) ->
      valid_registers (SLit x v) ->
      runsTo (withRegs   (map.put initialL.(getRegs) x (ZToReg v))
             (withPc     (add initialL.(getPc) d)
             (withNextPc (add initialL.(getNextPc) d)
                         initialL)))
             post ->
      runsTo initialL post.
  Proof.
    intros *. intros E1 insts d P V N. substs.
    lazymatch goal with
    | H1: valid_registers ?s |- _ =>
      pose proof (compile_stmt_emits_valid iset_is_supported H1 eq_refl) as EV
    end.
    simpl in *.
    destruct_RiscvMachine initialL.
    subst.
    unfold compile_lit in *.
    destruct (dec (- 2 ^ 11 <= v < 2 ^ 11));
      [|destruct (dec (width = 32 \/ - 2 ^ 31 <= v < 2 ^ 31))].
    - unfold compile_lit_12bit in *.
      run1det.
      simpl_word_exprs word_ok.
      match_apply_runsTo.
      erewrite signExtend_nop; eauto; blia.
    - unfold compile_lit_32bit in *.
      simpl in P.
      run1det. run1det.
      match_apply_runsTo.
      + rewrite map.put_put_same. f_equal.
        apply word.signed_inj.
        rewrite word.signed_of_Z.
        rewrite word.signed_xor.
        rewrite! word.signed_of_Z.
        change word.swrap with (signExtend width).
        assert (0 < width) as Wpos. {
          clear. destruct width_cases; rewrite H; reflexivity.
        }
        rewrite! signExtend_alt_bitwise by (reflexivity || assumption).
        clear -Wpos o.
        destruct o as [E | B ].
        * rewrite E. unfold signExtend_bitwise. Zbitwise.
        * unfold signExtend_bitwise. Zbitwise.
          (* TODO these should also be solved by Zbitwise *)
          {
            assert (32 <= i < width) by bomega. (* PARAMRECORDS? blia fails *)
            destruct B.
            assert (31 < i) by blia.
            assert (0 < 31) by reflexivity.
            erewrite testbit_above_signed' with (i := i); try eassumption.
            change (Z.log2_up (2 ^ 31)) with (32 - 1).
            Btauto.btauto.
          }
          {
            destruct B.
            assert (0 < 31) by reflexivity.
            assert (31 < width - 1) by blia.
            erewrite testbit_above_signed' with (i := width - 1); try eassumption.
            change (Z.log2_up (2 ^ 31)) with (32 - 1).
            Btauto.btauto.
          }
      + solve_word_eq word_ok.
      + solve_word_eq word_ok.
    - unfold compile_lit_64bit, compile_lit_32bit in *.
      match type of EV with
      | context [ Xori _ _ ?a ] => remember a as mid
      end.
      match type of EV with
      | context [ Z.lxor ?a mid ] => remember a as hi
      end.
      cbv [List.app program array] in P.
      simpl in *. (* if you don't remember enough values, this might take forever *)
      autorewrite with rew_Zlength in N.
      simpl in N.
      run1det.
      run1det.
      run1det.
      run1det.
      run1det.
      run1det.
      run1det.
      run1det.
      match_apply_runsTo.
      + rewrite! map.put_put_same. f_equal. subst.
        apply word.unsigned_inj.
        assert (width = 64) as W64. {
          clear -n0.
          destruct width_cases as [E | E]; rewrite E in *; try reflexivity.
          exfalso. apply n0. left. reflexivity.
        }
        (repeat rewrite ?word.unsigned_of_Z, ?word.unsigned_xor, ?word.unsigned_slu);
        unfold word.wrap;
        rewrite W64; try reflexivity.
        clear.
        change (10 mod 2 ^ 64) with 10.
        change (11 mod 2 ^ 64) with 11.
        rewrite <-! Z.land_ones by blia.
        rewrite! signExtend_alt_bitwise by reflexivity.
        unfold bitSlice, signExtend_bitwise.
        Zbitwise.
        (* TODO this should be done by Zbitwise, but not too eagerly because it's very
           expensive on large goals *)
        all: replace (i - 11 - 11 - 10 + 32) with i by blia.
        all: Btauto.btauto.
      + solve_word_eq word_ok.
      + solve_word_eq word_ok.
  Qed.

  Definition eval_stmt := exec map.empty.

  Lemma seplog_subst_eq{A B R: mem -> Prop} {mL mH: mem}
      (H: A mL)
      (H0: iff1 A (R * eq mH)%sep)
      (H1: B mH):
      (B * R)%sep mL.
  Proof.
    unfold iff1 in *.
    destruct (H0 mL) as [P1 P2]. specialize (P1 H).
    apply sep_comm.
    unfold sep in *.
    destruct P1 as (mR & mH' & P11 & P12 & P13). subst mH'. eauto.
  Qed.

  Lemma subst_load_bytes_for_eq {sz} {mH mL: mem} {addr: word} {bs P R}:
      let n := @Memory.bytes_per width sz in
      bedrock2.Memory.load_bytes n mH addr = Some bs ->
      (P * eq mH * R)%sep mL ->
      exists Q, (P * ptsto_bytes n addr bs * Q * R)%sep mL.
  Proof.
    intros n H H0.
    apply sep_of_load_bytes in H; cycle 1. {
      subst n. clear. destruct sz; destruct width_cases as [C | C]; rewrite C; cbv; discriminate.
    }
    destruct H as [Q A]. exists Q.
    assert (((ptsto_bytes n addr bs * Q) * (P * R))%sep mL); [|ecancel_assumption].
    eapply seplog_subst_eq; [exact H0|..|exact A]. ecancel.
  Qed.

  Ltac subst_load_bytes_for_eq :=
    match goal with
    | Load: bedrock2.Memory.load_bytes _ ?m _ = _, Sep: (_ * eq ?m * _)%sep _ |- _ =>
      let Q := fresh "Q" in
      destruct (subst_load_bytes_for_eq Load Sep) as [Q ?]
    end.

  Lemma store_bytes_frame: forall {n: nat} {m1 m1' m: mem} {a: word} {v: HList.tuple byte n} {F},
      Memory.store_bytes n m1 a v = Some m1' ->
      (eq m1 * F)%sep m ->
      exists m', (eq m1' * F)%sep m' /\ Memory.store_bytes n m a v = Some m'.
  Proof.
    intros.
    unfold sep in H0.
    destruct H0 as (mp & mq & A & B & C).
    subst mp.
    unfold map.split in A. destruct A as [A1 A2].
    eexists (map.putmany m1' mq).
    split.
    - unfold sep.
      exists m1', mq. repeat split; trivial.
      apply store_bytes_preserves_footprint in H.
      clear -H A2.
      unfold map.disjoint, map.same_domain, map.sub_domain in *. destruct H as [P Q].
      intros.
      edestruct Q; eauto.
    - subst m.
      eauto using disjoint_putmany_preserves_store_bytes.
  Qed.

  Ltac IH_sidecondition :=
    simpl_word_exprs (@word_ok (@W (@def_params p)));
    try solve
      [ reflexivity
      | auto
      | solve_stmt_not_too_big
      | solve_word_eq (@word_ok (@W (@def_params p)))
      | simpl; solve_divisibleBy4
      | prove_ext_guarantee
      | pseplog ].

  Arguments map.empty: simpl never.
  Arguments map.get: simpl never.

  Axiom compile_stmt_new_emits_valid: forall s e pos,
      supported_iset iset ->
      valid_registers s ->
      stmt_not_too_big s ->
      valid_instructions iset (compile_stmt_new e pos s).

  Axiom compile_function_emits_valid: forall e pos argnames resnames body,
      supported_iset iset ->
      Forall valid_register argnames ->
      Forall valid_register resnames ->
      valid_registers body ->
      stmt_not_too_big body ->
      valid_instructions iset (compile_function e pos (argnames, resnames, body)).

  Definition word_array: word -> list word -> mem -> Prop :=
    array (fun addr w => ptsto_bytes (@Memory.bytes_per width Syntax.access_size.word) addr
                                     (LittleEndian.split _ (word.unsigned w)))
          (word.of_Z (Z.of_nat (@Memory.bytes_per width Syntax.access_size.word))).

  Arguments Z.pow: simpl never.
  Arguments Z.sub: simpl never.
  Arguments compile_store: simpl never.
  Arguments compile_load: simpl never.

  (* TODO move *)

  Ltac use_sep_assumption :=
    match goal with
    | |- _ ?m1 =>
      match goal with
      | H: _ ?m2 |- _ =>
        unify m1 m2;
        refine (Lift1Prop.subrelation_iff1_impl1 _ _ _ _ _ H); clear H
      end
    end.

  Require Import coqutil.Tactics.syntactic_unify.

  Ltac cancel_seps_at_indices i j :=
    lazymatch goal with
    | |- Lift1Prop.iff1 (seps ?LHS) (seps ?RHS) =>
      simple refine (cancel_seps_at_indices i j LHS RHS _ _);
      cbn [firstn skipn app hd tl];
      [syntactic_exact_deltavar
         (@RelationClasses.reflexivity _ _
           (@RelationClasses.Equivalence_Reflexive _ _ (@Equivalence_iff1 _)) _) | ]
    end.

  Ltac cancel_seps_at_indices_by_iff i j :=
    lazymatch goal with
    | |- Lift1Prop.iff1 (seps ?LHS) (seps ?RHS) =>
      simple refine (cancel_seps_at_indices i j LHS RHS _ _);
      cbn [firstn skipn app hd tl]
    end.

  Lemma save_regs_correct: forall vars offset R initial p_sp oldvalues newvalues,
      Forall valid_register vars ->
      - 2 ^ 11 <= offset < 2 ^ 11 - bytes_per_word * Z.of_nat (length vars) ->
      divisibleBy4 initial.(getPc) ->
      map.getmany_of_list initial.(getRegs) vars = Some newvalues ->
      map.get initial.(getRegs) RegisterNames.sp = Some p_sp ->
      length oldvalues = length vars ->
      (program initial.(getPc) (save_regs vars offset) *
       word_array (word.add p_sp (word.of_Z offset)) oldvalues * R)%sep initial.(getMem) ->
      initial.(getNextPc) = word.add initial.(getPc) (word.of_Z 4) ->
      runsTo initial (fun final =>
          final.(getRegs) = initial.(getRegs) /\
          (program initial.(getPc) (save_regs vars offset) *
           word_array (word.add p_sp (word.of_Z offset)) newvalues * R)%sep
              final.(getMem) /\
          final.(getPc) = word.add initial.(getPc) (mul (word.of_Z 4)
                                                        (word.of_Z (Z.of_nat (length vars)))) /\
          final.(getNextPc) = word.add final.(getPc) (word.of_Z 4)).
  Proof.
    unfold map.getmany_of_list.
    induction vars; intros.
    - simpl in *. simp. destruct oldvalues; simpl in *; [|discriminate].
      apply runsToDone. repeat split; try assumption; try solve_word_eq word_ok.
    - simpl in *. simp.
      assert (valid_register RegisterNames.sp) by (cbv; auto).
      assert (valid_instructions EmitsValid.iset
                [(compile_store Syntax.access_size.word RegisterNames.sp a offset)]). {
        eapply compile_store_emits_valid; try eassumption.
        assert (bytes_per_word * Z.of_nat (S (length vars)) > 0). {
          unfold Z.of_nat.
          unfold bytes_per_word, Memory.bytes_per in *.
          destruct width_cases as [E1 | E1]; rewrite E1; reflexivity.
        }
        simpl. bomega.
      }
      destruct oldvalues as [|oldvalue oldvalues]; simpl in *; [discriminate|].
      eapply runsToStep. {
        eapply run_compile_store; try solve [sidecondition].
      }
      simpl. intros. simp.
      destruct_RiscvMachine initial.
      destruct_RiscvMachine mid.
      subst.
      eapply runsTo_weaken; cycle 1; [|eapply IHvars]. {
        simpl. intros. simp.
        repeat split; try solve [sidecondition].
        - (* TODO all of this should be one more powerful cancel tactic
             with matching of addresses using ring *)
          use_sep_assumption.
          cancel.
          unfold program.
          symmetry.
          cancel_seps_at_indices 1%nat 0%nat.
          unfold bytes_per_word, Memory.bytes_per.
          rewrite word.ring_morph_add.
          rewrite word.add_assoc.
          ecancel_step.
          ecancel.
        - replace (Z.of_nat (S (length oldvalues)))
            with (1 + Z.of_nat (length oldvalues)) by blia.
          etransitivity; [eassumption|].
          replace (length vars) with (length oldvalues) by blia.
          solve_word_eq word_ok.
      }
      all: try eassumption.
      + rewrite Nat2Z.inj_succ in *. rewrite <- Z.add_1_r in *.
        rewrite Z.mul_add_distr_l in *.
        remember (bytes_per_word * BinInt.Z.of_nat (length vars)) as K.
        assert (bytes_per_word > 0). {
          unfold bytes_per_word, Memory.bytes_per in *.
          destruct width_cases as [E1 | E1]; rewrite E1; reflexivity.
        }
        bomega.
      + simpl. solve_divisibleBy4.
      + simpl. pseplog.
        unfold bytes_per_word, Memory.bytes_per.
        rewrite word.ring_morph_add.
        rewrite word.add_assoc.
        ecancel.
      + reflexivity.
  Qed.

  Lemma length_save_regs: forall vars offset,
      length (save_regs vars offset) = length vars.
  Proof.
    induction vars; intros; simpl; rewrite? IHvars; reflexivity.
  Qed.

  (* x0 is the constant 0, x1 is ra, x2 is sp, the others are usable *)
  Definition valid_FlatImp_var(x: Register): Prop := 3 <= x < 32.

  Lemma load_regs_correct: forall p_sp vars offset R initial values,
      Forall valid_FlatImp_var vars ->
      NoDup vars ->
      - 2 ^ 11 <= offset < 2 ^ 11 - bytes_per_word * Z.of_nat (length vars) ->
      divisibleBy4 initial.(getPc) ->
      map.get initial.(getRegs) RegisterNames.sp = Some p_sp ->
      length values = length vars ->
      (program initial.(getPc) (load_regs vars offset) *
       word_array (word.add p_sp (word.of_Z offset)) values * R)%sep initial.(getMem) ->
      initial.(getNextPc) = word.add initial.(getPc) (word.of_Z 4) ->
      runsTo initial (fun final =>
          map.only_differ initial.(getRegs) (PropSet.of_list vars) final.(getRegs) /\
          map.getmany_of_list final.(getRegs) vars = Some values /\
          (program initial.(getPc) (load_regs vars offset) *
           word_array (word.add p_sp (word.of_Z offset)) values * R)%sep
              final.(getMem) /\
          final.(getPc) = word.add initial.(getPc) (mul (word.of_Z 4)
                                                        (word.of_Z (Z.of_nat (length vars)))) /\
          final.(getNextPc) = word.add final.(getPc) (word.of_Z 4)).
  Proof.
    induction vars; intros.
    - simpl in *. simp. destruct values; simpl in *; [|discriminate].
      apply runsToDone. repeat split; try assumption; try solve_word_eq word_ok.
      unfold map.only_differ. auto.
    - simpl in *. simp.
      assert (valid_register RegisterNames.sp) by (cbv; auto).
      assert (valid_register a). {
        unfold valid_register, valid_FlatImp_var in *. blia.
      }
      assert (valid_instructions EmitsValid.iset
                [(compile_load Syntax.access_size.word a RegisterNames.sp offset)]). {
        eapply compile_load_emits_valid; try eassumption.
        assert (bytes_per_word * Z.of_nat (S (length vars)) > 0). {
          unfold Z.of_nat.
          unfold bytes_per_word, Memory.bytes_per in *.
          destruct width_cases as [E1 | E1]; rewrite E1; reflexivity.
        }
        simpl. bomega.
      }
      destruct values as [|value values]; simpl in *; [discriminate|].
      eapply runsToStep. {
        eapply run_compile_load; try solve [sidecondition].
      }
      simpl. intros. simp.
      destruct_RiscvMachine initial.
      destruct_RiscvMachine mid.
      subst.
      eapply runsTo_weaken.
      + eapply IHvars; simpl; cycle -2; auto.
        * use_sep_assumption.
          match goal with
          | |- iff1 ?LHS ?RHS =>
            match LHS with
            | context [word_array ?i] =>
              match RHS with
              | context [word_array ?i'] =>
                replace i with i'; cycle 1
              end
            end
          end.
          { rewrite <- word.add_assoc. rewrite <- word.ring_morph_add. reflexivity. }
          cancel.
          ecancel_step.
          unfold bytes_per_word, Memory.bytes_per.
          ecancel_step.
          ecancel.
        * unfold bytes_per_word, Memory.bytes_per in *.
          rewrite Nat2Z.inj_succ in *. rewrite <- Z.add_1_r in *.
          rewrite Z.mul_add_distr_l in *.
          assert (bytes_per_word > 0). {
            unfold bytes_per_word, Memory.bytes_per in *.
            destruct width_cases as [E1 | E1]; rewrite E1; reflexivity.
          }
          bomega.
        * solve_divisibleBy4.
        * rewrite map.get_put_diff. 1: assumption.
          unfold RegisterNames.sp, valid_FlatImp_var in *. blia.
        * blia.
      + simpl. intros. simp.
        repeat split.
        * unfold map.only_differ, PropSet.elem_of, PropSet.of_list in *.
          intros x. rename H6 into HO.
          specialize (HO x).
          destruct (Z.eqb_spec x a).
          -- subst x. left. constructor. reflexivity.
          -- destruct HO as [HO | HO].
             ++ simpl. auto.
             ++ right. rewrite <- HO. rewrite map.get_put_diff; congruence.
        * unfold map.getmany_of_list in *. simpl. rewrite_match.
          rename H6 into HO.
          specialize (HO a). destruct HO as [HO | HO].
          -- unfold PropSet.elem_of, PropSet.of_list in HO. contradiction.
          -- unfold Register, MachineInt in *. rewrite <- HO.
             rewrite map.get_put_same. f_equal. f_equal.
             unfold id.
             rewrite LittleEndian.combine_split.
             apply word.unsigned_inj.
             rewrite word.unsigned_of_Z. unfold word.wrap.
             replace (BinInt.Z.of_nat (Z.to_nat ((width + 7) / 8)) * 8) with width; cycle 1. {
               clear. destruct width_cases as [E | E]; rewrite E; reflexivity.
             }
             rewrite !word.wrap_unsigned. reflexivity.
        * pseplog.
          match goal with
          | |- iff1 ?LHS ?RHS =>
            match LHS with
            | context [word_array ?i] =>
              match RHS with
              | context [word_array ?i'] =>
                replace i with i' by solve_word_eq word_ok
              end
            end
          end.
          unfold bytes_per_word, Memory.bytes_per.
          ecancel.
        * etransitivity; [eassumption|].
          rewrite Nat2Z.inj_succ. rewrite <- Z.add_1_r.
          replace (length values) with (length vars) by congruence.
          solve_word_eq word_ok.
        * assumption.
  Qed.

  Lemma length_load_regs: forall vars offset,
      length (load_regs vars offset) = length vars.
  Proof.
    induction vars; intros; simpl; rewrite? IHvars; reflexivity.
  Qed.

  (*
     high addresses!             ...
                      p_sp   --> mod_var_0 of previous function call arg0
                                 argn
                                 ...
                                 arg0
                                 retn
                                 ...
                                 ret0
                                 ra
                                 mod_var_n
                                 ...
                      new_sp --> mod_var_0
     low addresses               ...
  *)
  Definition stackframe(p_sp: word)(argvals retvals: list word)
             (ra_val: word)(modvarvals: list word): mem -> Prop :=
    word_array
      (word.add p_sp
                (word.of_Z
                   (- (bytes_per_word *
                       Z.of_nat (length argvals + length retvals + 1 + length modvarvals)))))
      (modvarvals ++ [ra_val] ++ retvals ++ argvals).

  (* measured in words, needs to be multiplied by 4 or 8 *)
  Definition framelength: list var * list var * stmt -> Z :=
    fun '(argvars, resvars, body) =>
      let mod_vars := modVars_as_list body in
      Z.of_nat (length argvars + length resvars + 1 + length mod_vars).

  Lemma framesize_nonneg: forall argvars resvars body,
      0 <= framelength (argvars, resvars, body).
  Proof.
    intros. unfold framelength.
    unfold bytes_per_word, Memory.bytes_per. blia.
  Qed.

  (* Note:
     - This predicate cannot be proved for recursive functions
     - Measured in words, needs to be multiplied by 4 or 8 *)
  Inductive fits_stack: Z -> env -> stmt -> Prop :=
  | fits_stack_load: forall n e sz x y,
      0 <= n ->
      fits_stack n e (SLoad sz x y)
  | fits_stack_store: forall n e sz x y,
      0 <= n ->
      fits_stack n e (SStore sz x y)
  | fits_stack_lit: forall n e x v,
      0 <= n ->
      fits_stack n e (SLit x v)
  | fits_stack_op: forall n e op x y z,
      0 <= n ->
      fits_stack n e (SOp x op y z)
  | fits_stack_set: forall n e x y,
      0 <= n ->
      fits_stack n e (SSet x y)
  | fits_stack_if: forall n e c s1 s2,
      fits_stack n e s1 ->
      fits_stack n e s2 ->
      fits_stack n e (SIf c s1 s2)
  | fits_stack_loop: forall n e c s1 s2,
      fits_stack n e s1 ->
      fits_stack n e s2 ->
      fits_stack n e (SLoop s1 c s2)
  | fits_stack_seq: forall n e s1 s2,
      fits_stack n e s1 ->
      fits_stack n e s2 ->
      fits_stack n e (SSeq s1 s2)
  | fits_stack_skip: forall n e,
      0 <= n ->
      fits_stack n e SSkip
  | fits_stack_call: forall n e binds fname args argnames retnames body,
      map.get e fname = Some (argnames, retnames, body) ->
      fits_stack (n - framelength (argnames, retnames, body)) e body ->
      fits_stack n e (SCall binds fname args)
  | fits_stack_interact: forall n e binds act args,
      0 <= n ->
      fits_stack n e (SInteract binds act args).

  Lemma fits_stack_nonneg: forall n e s,
      fits_stack n e s ->
      0 <= n.
  Proof.
    induction 1; try blia. pose proof (@framesize_nonneg argnames retnames body). blia.
  Qed.

  (* high stack addresses     | stackframe of main             \
                              ...                               \
    g|                        ---                                }- stuffed into R
    r|                        | stackframe of current func      /
    o|              p_sp -->  ---                              /
    w|                        |
    s|                        | currently unused stack
     |                        | (old_stackvals)
     V                        |
            p_stacklimit -->  ---

     low stack addresses *)

  Instance fun_pos_env: map.map Syntax.funname Z := _.

  (* Note: This definition would not be usable in the same way if we wanted to support
     recursive functions, because separation logic would prevent us from mentioning
     the snippet of code being run twice (once in [program initialL.(getPc) insts] and
     a second time inside [functions]).
     To avoid this double mentioning, we will remove the function being called from the
     list of functions before entering the body of the function. *)
  Definition functions(base: word)(rel_positions: fun_pos_env)(impls: env):
    list Syntax.funname -> mem -> Prop :=
    fix rec funnames :=
      match funnames with
      | nil => emp True
      | fname :: rest =>
        (match map.get rel_positions fname, map.get impls fname with
         | Some pos, Some impl =>
           program (word.add base (word.of_Z pos))
                   (compile_function rel_positions pos impl)
         | _, _ => emp True
         end * (rec rest))%sep
      end.

  Instance funname_eq_dec: DecidableEq Syntax.funname := _.

  Lemma functions_expose: forall base rel_positions impls funnames f pos impl,
      map.get rel_positions f = Some pos ->
      map.get impls f = Some impl ->
      iff1 (functions base rel_positions impls funnames)
           (functions base (map.remove rel_positions f)
                           (map.remove impls f)
                           (List.remove funname_eq_dec f funnames) *
            program (word.add base (word.of_Z pos)) (compile_function rel_positions pos impl))%sep.
  Proof.
  Admitted.

  Lemma compile_stmt_correct_new:
    forall (program_base: word),
    forall e_impl (s: stmt) t initialMH initialRegsH postH,
    exec e_impl s t initialMH initialRegsH postH ->
    (* note: [e_impl], [e_pos] and [funnames] will shrink one function at a time each time
       we enter a new function body, to make sure functions cannot call themselves *)
    forall e_pos funnames,
    (forall f impl, map.get e_impl f = Some impl ->
                    List.In f funnames /\
                    exists pos, map.get e_pos f = Some pos /\ pos mod 4 = 0) ->
    forall R initialL insts p_stacklimit p_sp p_ra old_stackvals pos,
    @compile_stmt_new def_params _ e_pos pos s = insts ->
    stmt_not_too_big s ->
    valid_registers s ->
    initialL.(getPc) = word.add program_base (word.of_Z pos) ->
    pos mod 4 = 0 ->
    divisibleBy4 program_base ->
    map.extends initialL.(getRegs) initialRegsH ->
    map.get initialL.(getRegs) RegisterNames.sp = Some p_sp ->
    map.get initialL.(getRegs) RegisterNames.ra = Some p_ra ->
    fits_stack (Z.of_nat (length old_stackvals)) e_impl s ->
    p_sp = word.add p_stacklimit
                    (word.of_Z (bytes_per_word * Z.of_nat (length old_stackvals))) ->
    (program initialL.(getPc) insts *
     functions program_base e_pos e_impl funnames *
     word_array p_stacklimit old_stackvals *
     eq initialMH * R)%sep initialL.(getMem) ->
    initialL.(getLog) = t ->
    initialL.(getNextPc) = add initialL.(getPc) (ZToReg 4) ->
    ext_guarantee initialL ->
    runsTo initialL (fun finalL => exists finalRegsH finalMH final_stackvals,
          postH finalL.(getLog) finalMH finalRegsH /\
          map.extends finalL.(getRegs) finalRegsH /\
          map.get finalL.(getRegs) RegisterNames.sp = Some p_sp ->
          map.get finalL.(getRegs) RegisterNames.ra = Some p_ra ->
          length final_stackvals = length old_stackvals /\
          (program initialL.(getPc) insts *
           word_array p_stacklimit final_stackvals *
           functions program_base e_pos e_impl funnames *
           eq finalMH * R)%sep finalL.(getMem) /\
          finalL.(getPc) = add initialL.(getPc) (mul (ZToReg 4) (ZToReg (Zlength insts))) /\
          finalL.(getNextPc) = add finalL.(getPc) (ZToReg 4) /\
          ext_guarantee finalL).
(* TODO these constrains will have to be added:
    Forall valid_FlatImp_var useargs ->
    Forall valid_FlatImp_var useresults ->
    Forall valid_FlatImp_var defargs ->
    Forall valid_FlatImp_var defresults ->

    (* note: use-site argument/result names are allowed to have duplicates, but definition-site
       argument/result names aren't *)
    NoDup defargs ->
    NoDup defresults ->
 *)
  Proof.
    pose proof compile_stmt_emits_valid.
    induction 1; intros;
      lazymatch goal with
      | H1: valid_registers ?s, H2: stmt_not_too_big ?s |- _ =>
        pose proof (@compile_stmt_new_emits_valid s e_pos pos iset_is_supported H1 H2)
      end;
      repeat match goal with
             | m: _ |- _ => destruct_RiscvMachine m
             end;
      simpl in *;
      subst;
      simp.

    - (* SInteract *)
      eapply runsTo_weaken.
      + eapply compile_ext_call_correct with
            (postH := fun t' m' lL' => exists lH', map.extends lL' lH' /\ post t' m' lH')
            (action0 := action) (argvars0 := argvars) (resvars0 := resvars);
          simpl; reflexivity || eassumption || ecancel_assumption || idtac.
        eapply @exec.interact; try eassumption.
        * eapply map.getmany_of_list_extends; eassumption.
        * intros mReceive resvals HO.
          match goal with
          | H: _ |- _ => specialize (H mReceive resvals HO);
                         destruct H as (finalRegsH & ? & finalMH & ? & ?)
          end.
          edestruct (map.putmany_of_list_extends_exists (ok := locals_ok))
            as (finalRegsL & ? & ?); [eassumption..|].
          eauto 7.
      + simpl. intros finalL A. destruct_RiscvMachine finalL. simpl in *.
        destruct_products. subst.
        do 3 eexists. repeat split; try eassumption. ecancel_assumption.

    - (* SCall *)
      (* We have one "map.get e fname" from exec, one from fits_stack, make them match *)
      match goal with
      | H1: map.get e_impl fname = ?RHS1, H2: map.get e_impl fname = ?RHS2 |- _ =>
        let F := fresh in
        assert (RHS1 = RHS2) as F by (etransitivity; [symmetry; exact H1 | exact H2]);
        inversion F; subst; clear F H2
      end.
      unfold fun_pos_env in *.
      match goal with
      | H: map.get e_impl fname = Some _, G: _ |- _ =>
          specialize G with (1 := H);
          destruct G as [? [funpos [GetPos ?] ] ]
      end.
      rewrite GetPos in *.
      (* normal rewrite doesn't always work *)
      match goal with
      | H: context [map.get e_pos fname] |- _ => setoid_rewrite GetPos in H
      end.

      set (FL := framelength (argnames, retnames, body)) in *.
      (* We have enough stack space for this call: *)
      assert (FL <= Z.of_nat (length old_stackvals)) as enough_stack_space. {
        match goal with
        | H: fits_stack _ _ _ |- _ => apply fits_stack_nonneg in H; clear -H
        end.
        blia.
      }

      assert (exists remaining_stack old_modvarvals old_ra old_retvals old_argvals,
                 old_stackvals = remaining_stack ++ old_modvarvals ++ [old_ra] ++
                                                 old_retvals ++ old_argvals /\
                 length old_modvarvals = length (modVars_as_list body) /\
                 length old_retvals = length retnames /\
                 length old_argvals = length argnames) as TheSplit. {
        subst FL. unfold framelength in *.
        clear -enough_stack_space.

        refine (ex_intro _ (List.firstn _ old_stackvals) _).
        refine (ex_intro _ (List.firstn _ (List.skipn _ old_stackvals)) _).
        refine (ex_intro _ (List.nth _ old_stackvals (word.of_Z 0)) _).
        refine (ex_intro _ (List.firstn _ (List.skipn _ old_stackvals)) _).
        refine (ex_intro _ (List.firstn _ (List.skipn _ old_stackvals)) _).

        assert (forall (T: Type) (l l1 l2: list T) (n: nat),
                   List.firstn n l = l1 ->
                   List.skipn n l = l2 ->
                   l = l1 ++ l2) as firstn_skipn_reassemble. {
          intros. subst. symmetry. apply firstn_skipn.
        }
        assert (forall (T: Type) (i: nat) (L: list T) (d: T),
                   (i < length L)%nat ->
                   List.firstn 1 (List.skipn i L) = [List.nth i L d]) as firstn_skipn_nth. {
          induction i; intros.
          - simpl. destruct L; simpl in *; try (exfalso; blia). reflexivity.
          - simpl. destruct L; try (simpl in *; exfalso; blia). simpl.
            rewrite <- IHi; [reflexivity|]. simpl in *. blia.
        }

        repeat split.
        1: eapply firstn_skipn_reassemble; [reflexivity|].
        1: eapply firstn_skipn_reassemble; [reflexivity|].
        1: rewrite List.skipn_skipn.
        1: eapply firstn_skipn_reassemble.
        1: eapply firstn_skipn_nth.
        2: rewrite List.skipn_skipn.
        2: eapply firstn_skipn_reassemble; [reflexivity|].
        2: rewrite List.skipn_skipn.
        2: rewrite firstn_all.
        2: reflexivity.
        2: rewrite List.length_firstn_inbounds.
        2: reflexivity.
        3: rewrite List.length_firstn_inbounds.
        3: reflexivity.
        4: rewrite List.length_firstn_inbounds.
        4: rewrite List.length_skipn.
        4: lazymatch goal with
           | |- ?LHS = ?RHS =>
             match LHS with
             | context C [ ?x ] =>
               is_evar x;
               let LHS' := context C [ 0%nat ] in
               assert (LHS' - RHS = x)%nat
             end
           end.
        4: reflexivity.

        all: rewrite ?List.length_skipn.
        all: try blia.
      }
      destruct TheSplit as (remaining_stack & old_modvarvals & old_ra & old_retvals & old_argvals
                                & ? & ? &  ? & ?).
      subst old_stackvals.

      assert (forall ks vs (m0: locals),
                 map.getmany_of_list m0 ks = Some vs ->
                 length ks = length vs) as getmany_of_list_length. {
        induction ks; intros vs m0 E.
        - inversion E. reflexivity.
        - cbn in E. destruct (map.get m0 a) eqn: F; try discriminate.
          destruct (List.option_all (map (map.get m0) ks)) eqn: G; try discriminate.
          inversion E.
          simpl.
          f_equal.
          eapply IHks.
          eassumption.
      }

      assert (length old_argvals = length args). {
        match goal with
        | H: _ |- _ => apply map.putmany_of_list_sameLength in H; move H at bottom
        end.
        match goal with
        | H: _ |- _ => apply getmany_of_list_length in H; move H at bottom
        end.
          (* TODO it's bad we need that (kind of PARAMRECORDS) *)
        unfold Register, MachineInt in *.
        congruence.
      }

      (* put arguments on stack *)
      eapply runsTo_trans. {
        eapply save_regs_correct with (vars := args) (offset := - bytes_per_word * Z.of_nat (length args)); simpl;
          try solve [sidecondition].
        - admit.
        - solve_divisibleBy4.
        - eapply map.getmany_of_list_extends; eassumption.
        - instantiate (1 := old_argvals).
          eassumption.
        - use_sep_assumption.
          unfold program, word_array.
          progress repeat match goal with
                          | |- context [ array ?PT ?SZ ?start (?xs ++ ?ys) ] =>
                            rewrite (array_append_DEPRECATED PT SZ xs ys start)
                          end.
          cancel.
          cancel_seps_at_indices_by_iff 6%nat 0%nat. {
            match goal with
            | |- iff1 (array _ _ ?p1 _) (array _ _ ?p2 _) =>
              replace p2 with p1; [exact (RelationClasses.reflexivity _)|]
            end.

            (* TODO should be part of simpl_word_exprs *)
            rewrite ?app_length.
            rewrite !Zlength_correct.
            change (length [old_ra]) with 1%nat.
            rewrite ?Nat2Z.inj_add.
            unfold bytes_per_word, Memory.bytes_per.
            autorewrite with rew_word_morphism.
            simpl_word_exprs word_ok.
            change BinInt.Z.of_nat with Z.of_nat.
            replace (length old_argvals) with (length args) by blia.
            replace (length old_retvals) with (length retnames) by blia.
            solve_word_eq word_ok.
          }
          exact (RelationClasses.reflexivity _).
      }

    cbn [getRegs getPc getNextPc getMem getLog].
    repeat match goal with
           | H: (_ * _)%sep _ |- _ => clear H
           end.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    assert (valid_register RegisterNames.ra) by (cbv; auto).
    assert (valid_register RegisterNames.sp) by (cbv; auto).

    (* jump to function *)
    eapply runsToStep. {
      eapply run_Jal; simpl; try solve [sidecondition | solve_divisibleBy4].
      rewrite Zlength_correct in *.
      rewrite length_save_regs in *.
      ecancel_assumption.
    }

    cbn [getRegs getPc getNextPc getMem getLog].
    repeat match goal with
           | H: (_ * _)%sep _ |- _ => clear H
           end.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    pose proof functions_expose as P.
    do 2 match goal with
    | H: _ |- _ => specialize P with (1 := H)
    end.
    specialize (P program_base funnames).
    seprewrite_in P H17. clear P.

Ltac ret_type P :=
  lazymatch P with
  | forall x, @?Q x => let Q' := open_constr:(Q _) in
                       let Q'' := eval cbv beta in Q' in
                           ret_type Q''
  | _ -> ?Q => ret_type Q
  | ?Q => open_constr:(Q)
  end.

Ltac _especialize_as P H :=
  let T := type of P in
  let R := ret_type T in
  assert R as H; [eapply P|].

Ltac _especialize H :=
  let T := type of H in
  let R := ret_type T in
  let N := fresh in
  rename H into N;
  assert R as H; [eapply N|]; clear N.

Tactic Notation "especialize" constr(P) "as" ident(H) := _especialize_as P H.
(* Tactic Notation "especialize" ident(H) := _especialize H. TODO how can these two
   live together? *)

    pose proof (@compile_function_emits_valid e_pos funpos argnames retnames body) as V.
    _especialize V.
    { exact iset_is_supported. }
    { admit. (* valid argnames *) }
    { admit. (* valid retnames *) }
    { admit. (* valid_registers for function being called *) }
    { admit. (* stmt_not_too_big for function being called *) }

    simpl in *.

    (* decrease sp *)
    eapply runsToStep. {
      eapply run_Addi; try solve [sidecondition | simpl; solve_divisibleBy4 ].
      - simpl.
        rewrite map.get_put_diff by (clear; cbv; congruence).
        eassumption.
      - simpl.
        use_sep_assumption.
        cancel.
        cancel_seps_at_indices_by_iff 1%nat 0%nat. {
          (* address mismatch BUG:
             in compile_stmt_new/case SCall, the Jal should subtract `mypos + 4 * length argvars`
             instead of `mypos` *)
          admit.
        }
        admit.
    }

    cbn [getRegs getPc getNextPc getMem getLog].
    repeat match goal with
           | H: context [sep] |- _ => clear H
           end.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* save ra on stack *)
    eapply runsToStep. {
      eapply run_compile_store; try solve [sidecondition | simpl; solve_divisibleBy4]. {
        simpl.
        rewrite map.get_put_diff by (clear; cbv; congruence).
        rewrite map.get_put_same. reflexivity.
      }
      admit.
    }

  Abort.

  Lemma compile_stmt_correct:
    forall (s: stmt) t initialMH initialRegsH postH,
    eval_stmt s t initialMH initialRegsH postH ->
    forall R initialL insts,
    @compile_stmt def_params s = insts ->
    stmt_not_too_big s ->
    valid_registers s ->
    divisibleBy4 initialL.(getPc) ->
    initialL.(getRegs) = initialRegsH ->
    (program initialL.(getPc) insts * eq initialMH * R)%sep initialL.(getMem) ->
    initialL.(getLog) = t ->
    initialL.(getNextPc) = add initialL.(getPc) (ZToReg 4) ->
    ext_guarantee initialL ->
    runsTo initialL (fun finalL => exists finalMH,
          postH finalL.(getLog) finalMH finalL.(getRegs) /\
          (program initialL.(getPc) insts * eq finalMH * R)%sep finalL.(getMem) /\
          finalL.(getPc) = add initialL.(getPc) (mul (ZToReg 4) (ZToReg (Zlength insts))) /\
          finalL.(getNextPc) = add finalL.(getPc) (ZToReg 4) /\
          ext_guarantee finalL).
  Proof.
    pose proof compile_stmt_emits_valid.
    induction 1; intros;
      lazymatch goal with
      | H1: valid_registers ?s, H2: stmt_not_too_big ?s |- _ =>
        pose proof (compile_stmt_emits_valid iset_is_supported H1 H2)
      end;
      repeat match goal with
             | m: _ |- _ => destruct_RiscvMachine m
             end;
      simpl in *;
      subst;
      simp.

    - (* SInteract *)
      eapply runsTo_weaken.
      + eapply compile_ext_call_correct with (postH := post) (action0 := action)
                                             (argvars0 := argvars) (resvars0 := resvars);
          simpl; reflexivity || eassumption || ecancel_assumption || idtac.
        eapply @exec.interact; try eassumption.
      + simpl. intros finalL A. destruct_RiscvMachine finalL. simpl in *.
        destruct_products. subst. eauto 7.

    - (* SCall *)
      match goal with
      | A: map.get map.empty _ = Some _ |- _ =>
        clear -A; exfalso; simpl in *;
        rewrite map.get_empty in A
      end.
      discriminate.

    - (* SLoad *)
      unfold Memory.load, Memory.load_Z in *. simp. subst_load_bytes_for_eq.
      run1det. run1done.

    - (* SStore *)
      assert ((eq m * (program initialL_pc [[compile_store sz a v 0]] * R))%sep initialL_mem)
             as A by ecancel_assumption.
      pose proof (store_bytes_frame H2 A) as P.
      destruct P as (finalML & P1 & P2).
      run1det. run1done.

    - (* SLit *)
      eapply compile_lit_correct_full.
      + sidecondition.
      + unfold compile_stmt. unfold getPc, getMem. ecancel_assumption.
      + sidecondition.
      + simpl. run1done.

      (* SOp *)
    - match goal with
      | o: Syntax.bopname.bopname |- _ => destruct o
      end;
      simpl in *; run1det; try solve [run1done].
      run1det. run1done.
      match goal with
      | H: ?post _ _ _ |- ?post _ _ _ => eqexact H
      end.
      rewrite reduce_eq_to_sub_and_lt.
      symmetry. apply map.put_put_same.

    - (* SSet *)
      run1det. run1done.

    - (* SIf/Then *)
      (* execute branch instruction, which will not jump *)
      eapply runsTo_det_step; simpl in *; subst.
      + simulate'.
        destruct cond; [destruct op | ];
          simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity.
      + eapply runsTo_trans.
        * (* use IH for then-branch *)
          eapply IHexec; IH_sidecondition.
        * (* jump over else-branch *)
          simpl. intros. simp. destruct_RiscvMachine middle. subst.
          run1det. run1done.

    - (* SIf/Else *)
      (* execute branch instruction, which will jump over then-branch *)
      eapply runsTo_det_step; simpl in *; subst.
      + simulate'.
        destruct cond; [destruct op | ];
          simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity.
      + eapply runsTo_trans.
        * (* use IH for else-branch *)
          eapply IHexec; IH_sidecondition.
        * (* at end of else-branch, i.e. also at end of if-then-else, just prove that
             computed post satisfies required post *)
          simpl. intros. simp. destruct_RiscvMachine middle. subst. run1done.

    - (* SLoop/again *)
      on hyp[(stmt_not_too_big body1); runsTo] do (fun H => rename H into IH1).
      on hyp[(stmt_not_too_big body2); runsTo] do (fun H => rename H into IH2).
      on hyp[(stmt_not_too_big (SLoop body1 cond body2)); runsTo] do (fun H => rename H into IH12).
      eapply runsTo_trans.
      + (* 1st application of IH: part 1 of loop body *)
        eapply IH1; IH_sidecondition.
      + simpl in *. simpl. intros. simp. destruct_RiscvMachine middle. subst.
        destruct (@eval_bcond (@Semantics_params p) middle_regs cond) as [condB|] eqn: E.
        2: exfalso;
           match goal with
           | H: context [_ <> None] |- _ => solve [eapply H; eauto]
           end.
        destruct condB.
        * (* true: iterate again *)
          eapply runsTo_det_step; simpl in *; subst.
          { simulate'.
            destruct cond; [destruct op | ];
              simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity. }
          { eapply runsTo_trans.
            - (* 2nd application of IH: part 2 of loop body *)
              eapply IH2; IH_sidecondition.
            - simpl in *. simpl. intros. simp. destruct_RiscvMachine middle. subst.
              (* jump back to beginning of loop: *)
              run1det.
              eapply runsTo_trans.
              + (* 3rd application of IH: run the whole loop again *)
                eapply IH12; IH_sidecondition.
              + (* at end of loop, just prove that computed post satisfies required post *)
                simpl. intros. simp. destruct_RiscvMachine middle. subst.
                run1done. }
        * (* false: done, jump over body2 *)
          eapply runsTo_det_step; simpl in *; subst.
          { simulate'.
            destruct cond; [destruct op | ];
              simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity. }
          { simpl in *. run1done. }

    - (* SSeq *)
      rename IHexec into IH1, H2 into IH2.
      eapply runsTo_trans.
      + eapply IH1; IH_sidecondition.
      + simpl. intros. simp. destruct_RiscvMachine middle. subst.
        eapply runsTo_trans.
        * eapply IH2; IH_sidecondition.
        * simpl. intros. simp. destruct_RiscvMachine middle. subst. run1done.

    - (* SSkip *)
      run1done.
  Qed.

  Context {fun_pos_env : map.map Syntax.funname Z}.

  Ltac simpl_program_sep H :=
    unfold program in H;
    repeat match type of H with
           | context [ array ?PT ?SZ ?start (?x :: ?xs) ] =>
             seprewrite0_in (array_cons PT SZ x xs start) H
        (*
           | H: _ ?m |- _ ?m => progress (simpl in * (* does array_cons *))
           | H: context [array _ _ ?addr1 ?content] |- context [array _ _ ?addr2 ?content] =>
             progress replace addr1 with addr2 in H by ring;
               ring_simplify addr2;
               ring_simplify addr2 in H
           (* just unprotected seprewrite will instantiate evars in undesired ways *)
           | |- context [ array ?PT ?SZ ?start (?xs ++ ?ys) ] =>
             seprewrite0 (array_append_DEPRECATED PT SZ xs ys start)
*)
           | context [ array ?PT ?SZ ?start (?xs ++ ?ys) ] =>
             seprewrite0_in (array_append_DEPRECATED PT SZ xs ys start) H
           end.

  Require Import Coq.Classes.Morphisms.

  Definition holds(P: mem -> Prop)(m: mem): Prop := P m.
  Instance holds_Proper: Proper (iff1 ==> eq ==> iff) holds.
  Proof.
    unfold Proper, iff1, iff, holds, respectful.
    generalize (@map.rep _ _ (@mem p)).
    clear.
    firstorder congruence.
  Qed.

  Lemma length_list_union: forall {T: Type} {teq: DecidableEq T} (l1 l2: list T),
      (length (ListLib.list_union l1 l2) <= length l1 + length l2)%nat.
  Proof.
    induction l1; intros; simpl; [blia|].
    destruct_one_match.
    - specialize (IHl1 l2). blia.
    - specialize (IHl1 (a :: l2)). simpl in *. blia.
  Qed.

  (* not a very strong bound, but requires no preconditions *)
  Lemma modVars_as_list_le_stmt_size: forall (s: @stmt (mk_Syntax_params _)),
      Z.of_nat (length (modVars_as_list s)) <= FlatImp.stmt_size s.
  Proof.
    induction s; simpl; try blia.
    (* call and interact cases still need more conditions *)
  Abort.

  Lemma union_Forall: forall {T: Type} {teq: DecidableEq T} (P: T -> Prop) (l1 l2: list T),
      Forall P l1 ->
      Forall P l2 ->
      Forall P (ListLib.list_union l1 l2).
  Proof.
    induction l1; intros; simpl; [assumption|].
    simp. destruct_one_match; eauto.
  Qed.

  Lemma modVars_as_list_valid_registers: forall (s: @stmt (mk_Syntax_params _)),
      valid_registers s ->
      Forall valid_register (modVars_as_list s).
  Proof.
    induction s; intros; simpl in *; simp; eauto 10 using @union_Forall.
  Qed.

  Axiom TODO: False.

  Ltac linearize_list l :=
    lazymatch l with
    | @nil ?T => constr:(@nil (list T))
    | ?h :: ?t => let ts := linearize_list t in constr:([h] :: ts)
    | ?t1 ++ ?t2 => let ts1 := linearize_list t1 in
                    let ts2 := linearize_list t2 in
                    constr:(ts1 ++ ts2)
    | ?L => constr:([L])
    end.

  Ltac concatenize l :=
    let l' := linearize_list l in
    let l'' := eval cbv [List.app] in l' in
        replace l with (List.concat l'').

  Definition sum_lengths{T: Type}(L: list (list T)): nat :=
    List.fold_right (fun l s => (length l + s)%nat) 0%nat L.

  Lemma push_skipn_into_concat: forall {T: Type} (m n: nat) (L: list (list T)),
      sum_lengths (List.firstn m L) = n ->
      List.skipn n (List.concat L) = List.concat (List.skipn m L).
  Proof.
    induction m; intros.
    - simpl in *. subst n. rewrite List.skipn_0_l. reflexivity.
    - simpl in *.
      destruct L as [|l L].
      + destruct n; simpl in *; try congruence.
      + simpl in *. subst n. erewrite <- IHm; [|reflexivity].
        rewrite List.skipn_app.
        rewrite minus_plus.
        rewrite List.skipn_all by blia.
        reflexivity.
  Qed.

  Lemma push_firstn_into_concat: forall {T: Type} (m n: nat) (L: list (list T)),
      sum_lengths (List.firstn m L) = n ->
      List.firstn n (List.concat L) = List.concat (List.firstn m L).
  Proof.
    induction m; intros.
    - simpl in *. subst n. reflexivity.
    - simpl in *.
      destruct L as [|l L].
      + destruct n; simpl in *; try congruence.
      + simpl in *. subst n. erewrite <- IHm; [|reflexivity].
        rewrite List.firstn_app.
        rewrite minus_plus.
        rewrite List.firstn_all2 by blia.
        reflexivity.
  Qed.

  Ltac is_nat_const n :=
    lazymatch isnatcst n with
    | true => idtac
    | false => fail "the number" n "is not a nat constant"
    end.

  Arguments List.firstn : simpl never.
  Arguments List.skipn: simpl never.

  Definition ll_regs: PropSet.set Register :=
    PropSet.union (PropSet.singleton_set RegisterNames.sp)
                  (PropSet.singleton_set RegisterNames.ra).

  Definition hl_regs: PropSet.set Register :=
    fun r => 3 <= r < 32. (* x0 is the constant 0, x1 is ra, x2 is sp, the others are usable *)

  Lemma getmany_of_list_defined{K V: Type}{M: map.map K V}: forall (m: M) (keys: list K),
      Forall (fun k => map.get m k <> None) keys ->
      exists values, map.getmany_of_list m keys = Some values.
  Proof.
    induction keys; intros.
    - exists nil. reflexivity.
    - inversion H. subst. destruct (map.get m a) eqn: E; try contradiction.
      edestruct IHkeys as [vs IH]; [assumption|].
      exists (v :: vs). cbn. rewrite E. unfold map.getmany_of_list in IH.
      rewrite IH. reflexivity.
  Qed.

  Lemma compile_function_correct:
    forall body useargs useresults defargs defresults t initialMH (initialRegsH: locals)
           postH argvals sublocals outcome,
      (* FlatImp function execution works: *)
      map.getmany_of_list initialRegsH useargs = Some argvals ->
      map.putmany_of_list defargs argvals map.empty = Some sublocals ->
      exec map.empty body t initialMH sublocals outcome ->
      (forall (t' : trace) (m' : mem) (st : locals),
          outcome t' m' st ->
          exists (retvals : list word) (l' : locals),
            map.getmany_of_list st defresults = Some retvals /\
            map.putmany_of_list useresults retvals initialRegsH = Some l' /\
            postH t' m' l') ->
    forall R initialL insts e pos p_ra p_sp old_retvals old_ra old_modvarvals,
    length argvals = length defargs ->
    length old_retvals = length defresults ->
    length old_modvarvals = length (modVars_as_list body) ->
    Forall valid_FlatImp_var useargs ->
    Forall valid_FlatImp_var useresults ->
    Forall valid_FlatImp_var defargs ->
    Forall valid_FlatImp_var defresults ->
    (* note: use-site argument/result names are allowed to have duplicates, but definition-site
       argument/result names aren't *)
    NoDup defargs ->
    NoDup defresults ->
    @compile_function def_params fun_pos_env e pos (defargs, defresults, body) = insts ->
    stmt_not_too_big body ->
    valid_registers body ->
    divisibleBy4 initialL.(getPc) ->
    (forall r, hl_regs r <-> map.get initialRegsH r <> None) ->
    map.only_differ initialL.(getRegs) ll_regs initialRegsH ->
    map.get initialL.(getRegs) RegisterNames.sp = Some p_sp ->
    map.get initialL.(getRegs) RegisterNames.ra = Some p_ra ->
    (program initialL.(getPc) insts *
     stackframe p_sp argvals old_retvals old_ra old_modvarvals *
     eq initialMH * R)%sep initialL.(getMem) ->
    initialL.(getLog) = t ->
    initialL.(getNextPc) = add initialL.(getPc) (word.of_Z 4) ->
    ext_guarantee initialL ->
    runsTo initialL (fun finalL => exists finalMH,
          postH finalL.(getLog) finalMH (map.remove (map.remove finalL.(getRegs)
                                               RegisterNames.sp) RegisterNames.ra) /\
          (program initialL.(getPc) insts * eq finalMH * R)%sep finalL.(getMem) /\
          finalL.(getPc) = add initialL.(getPc) (mul (word.of_Z 4) (word.of_Z (Zlength insts))) /\
          finalL.(getNextPc) = add finalL.(getPc) (word.of_Z 4) /\
          ext_guarantee finalL).
  Proof.
    intros.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    simpl in *.
    assert (valid_instructions EmitsValid.iset insts) by case TODO.
    assert (valid_register RegisterNames.sp). {
      cbv. auto.
    }
    assert (valid_register RegisterNames.ra). {
      cbv. auto.
    }
    subst.

    (* decrease sp *)
    eapply runsToStep. {
      eapply run_Addi; try solve [sidecondition | simpl; solve_divisibleBy4 ].
    }

    cbn [getRegs getPc getNextPc getMem getLog].
    repeat match goal with
           | H: context [sep] |- _ => clear H
           end.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* save ra on stack *)
    eapply runsToStep. {
      eapply run_compile_store; try solve [sidecondition | simpl; solve_divisibleBy4].
      {
        simpl.
        rewrite map.get_put_diff by (clear; cbv; congruence).
        eassumption.
      }
      {
      simpl.
      use_sep_assumption.
      unfold stackframe, word_array in *.
      rewrite array_address_inbounds.
      { unfold Memory.bytes_per. ecancel. }
      { rewrite ?List.app_length. simpl.
        remember (Z.of_nat (length old_modvarvals + S (length old_retvals + length argvals)))
          as F.
        replace (Z.of_nat (length argvals + length old_retvals + 1 + length old_modvarvals))
                with F by blia.
        change (Z.of_nat (Z.to_nat ((width + 7) / 8))) with bytes_per_word.
        rewrite word.unsigned_of_Z. unfold word.wrap.
        replace (bytes_per_word mod 2 ^ width) with bytes_per_word; cycle 1. {
          clear. unfold bytes_per_word. simpl.
          destruct width_cases as [E | E]; rewrite E; reflexivity.
        }

        replace (Z.of_nat
                   (length defargs + length defresults + 1 + length (modVars_as_list body)))
          with F;
        (* PARAMRECORDS *) simpl;
        [|blia].
        match goal with
          | |- word.unsigned ?x < _ => ring_simplify x
        end.

        rewrite word.unsigned_mul, ?word.unsigned_of_Z. unfold word.wrap.
        rewrite Zmult_mod_idemp_r. rewrite Zmult_mod_idemp_l.
        rewrite Z.mod_small.
        - apply Z.mul_lt_mono_pos_l; [|blia].
          unfold bytes_per_word, Memory.bytes_per. clear.
          destruct width_cases as [E | E]; rewrite E; reflexivity.
        - case TODO. (* length of list of mod vars *)
      }
      { case TODO. (* something modulo bytes_per_word = 0 *) }
      { reflexivity. }
      }
    }

    cbn [getRegs getPc getNextPc getMem getLog].
    repeat match goal with
           | H: context [sep] |- _ => clear H
           end.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* save vars modified by callee onto stack *)
    match goal with
    | |- context [ {| getRegs := ?l |} ] =>
      pose proof (@getmany_of_list_defined _ _ _ l (modVars_as_list body)) as P
    end.
    edestruct P as [newvalues P2]. {
      move H10 at bottom.
      admit.
    }
    eapply runsTo_trans. {
      eapply save_regs_correct; simpl; cycle 2.
      1: solve_divisibleBy4.
      2: rewrite map.get_put_same; reflexivity.
      1: exact P2.
      4: eapply modVars_as_list_valid_registers; eassumption.
      1: eassumption.
      2: reflexivity.
      1: {
        use_sep_assumption.
        unfold program.
        progress repeat match goal with
                        | |- context [ array ?PT ?SZ ?start (?xs ++ ?ys) ] =>
                          rewrite (array_append_DEPRECATED PT SZ xs ys start)
                        end.
        cancel.
        simpl_word_exprs word_ok.

        (* PARAMRECORDS *) change Syntax.varname with Register in *.
        ecancel_step.
        replace (Z.of_nat (length argvals + length old_retvals + 1 + length old_modvarvals))
          with (Z.of_nat (length defargs + length defresults + 1 + length (modVars_as_list body)))
          by (simpl; blia).
        rewrite ?Nat2Z.inj_add in *.
        change BinInt.Z.of_nat with Z.of_nat in *.
        change BinInt.Z.to_nat with Z.to_nat in *.
        change (Z.of_nat 1) with 1 in *.
        match goal with
        | |- context [word.unsigned ?x / word.unsigned _] => ring_simplify x
        end.
        change (Z.of_nat (Z.to_nat ((width + 7) / 8))) with bytes_per_word.
        rewrite word.unsigned_mul.
        rewrite ?word.unsigned_of_Z. unfold word.wrap.
        replace (bytes_per_word mod 2 ^ width) with bytes_per_word; cycle 1. {
          clear. unfold bytes_per_word. destruct width_cases as [E | E]; rewrite E; reflexivity.
        }
        rewrite Z.mul_mod_idemp_r; cycle 1. {
          clear. destruct width_cases as [E | E]; rewrite E; cbv; discriminate.
        }
        assert (0 <= bytes_per_word * Z.of_nat (length (modVars_as_list body)) < 2 ^ width). {
          case TODO.
        }
        rewrite Z.mod_small by assumption.
        rewrite !(Z.mul_comm bytes_per_word).
        rewrite Z.div_mul; cycle 1. {
          clear. unfold bytes_per_word.
          destruct width_cases as [E | E]; rewrite E; cbv; discriminate.
        }
        rewrite !Nat2Z.id.
        replace (length (modVars_as_list body)) with (length old_modvarvals) by blia.

        match goal with
        | |- context [List.skipn _ ?l] =>
          concatenize l;
            [|cbn [List.concat List.app]; rewrite ?List.app_nil_r; reflexivity]
        end.

        rewrite (push_skipn_into_concat 2); cycle 1. {
          cbv [sum_lengths List.firstn List.fold_right]. simpl. blia.
        }
        rewrite (push_firstn_into_concat 1); cycle 1. {
          cbv [sum_lengths List.firstn List.fold_right]. simpl. blia.
        }

        match goal with
        | |- context [List.skipn ?n ?L] =>
          is_nat_const n;
            let r := eval cbv [List.skipn] in (List.skipn n L) in
                change (List.skipn n L) with r
        end.
        match goal with
        | |- context [List.firstn ?n ?L] =>
          is_nat_const n;
            let r := eval cbv [List.firstn] in (List.firstn n L) in
                change (List.firstn n L) with r
        end.

        repeat match goal with
        | |- context [List.concat ?L] =>
            let r := eval cbn [List.concat List.app] in (List.concat L) in
                change (List.concat L) with r
        end.
        rewrite !List.app_nil_r.

        unfold word_array, bytes_per_word.
        replace (length (modVars_as_list body)) with (length old_modvarvals) by blia.
        unfold Memory.bytes_per.
        simpl_word_exprs word_ok.
        cancel_step.
        ecancel.
      }
      admit.
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog].
    repeat match goal with
           | H: context [sep] |- _ => clear H
           end.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* load argvars from stack *)
    eapply runsTo_trans. {
      eapply load_regs_correct; simpl; cycle -2; try assumption.
      - use_sep_assumption.
        progress repeat match goal with
        | |- context [ array ?PT ?SZ ?start (?xs ++ ?ys) ] =>
          rewrite (array_append_DEPRECATED PT SZ xs ys start)
        end.
        unfold program.
        rewrite ?Zlength_correct.
        rewrite ?length_save_regs.
        cancel.
        cancel_seps_at_indices_by_iff 5%nat 0%nat. {
          exact (RelationClasses.reflexivity _). (* some expensive unification *)
        }
        cancel_seps_at_indices_by_iff 12%nat 0%nat. {
          unfold iff1. intro m.
          assert (forall (P Q: Prop), P = Q -> P <-> Q) as A. {
            intros; subst; tauto.
          }
          apply A.
          unfold word_array.
          f_equal.
          match goal with
          | |- ?x = ?y => ring_simplify x y
          end.
          assert (forall (a b c: word), word.sub a b = c -> a = word.add b c) as D. {
            intros. subst. clear. ring.
          }
          apply D.
          reflexivity.
        }
        exact (RelationClasses.reflexivity _). (* just instantiates frame *)
      - reflexivity.
      - assumption.
      - assumption.
      - admit.
      - solve_divisibleBy4.
      - rewrite map.get_put_same. f_equal.
        admit. (*
        simpl_word_exprs word_ok.
        solve_word_eq word_ok. *)
      - blia.
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog].
    repeat match goal with
           | H: context [sep] |- _ => clear H
           end.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* execute function body *)
    eapply runsTo_trans. {
      eapply compile_stmt_correct; simpl; try assumption.
      - eassumption.
      - reflexivity.
      - assumption.
      - assumption.
      - solve_divisibleBy4.
      - (* TODO will have to adapt hyp
           "getRegs initialL = initialRegsH"
           of compile_stmt_correct *)

  Abort.

End FlatToRiscv1.
