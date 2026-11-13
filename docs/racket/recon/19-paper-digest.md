# Recon 19: paper digest, "A Programming Paradigm for Spatiotemporal Composability"

Source: Yifan Shi, Wei Zhang, Tianyi Cui (Peking University, DeepSeek-AI), arXiv:2608.25512, read from the plain-text extraction `cordis-paper-2608.25512.txt` (7,953 lines). Line ranges read, in order and without gaps: 1-700, 700-1449, 1450-2199, 2200-2949, 2950-3699, 3700-4499, 4500-5299, 5300-6099, 6100-6749, 6750-7369, 7370-7953. Section positions in that file: §1 at 103, §2 at 239, §3 at 326 (§3.1 339, §3.2 1283, §3.3 1616, §3.4 2187), §4 at 2853 (§4.2 3123, §4.3 3594, §4.4 5960), §5 at 6062 (§5.2 6545, §5.3 6907), §6 at 6965, §7 at 7284, §8 at 7548, references 7576-7953.

This note uses the section headings the task assigned to this area instead of the standard recon headings. Citations of the form "paper:N" are line numbers in the extraction. Citations of the form `vendor/cordis/src/...:N` are the vendored kernel at pinned commit `e8f7b93a3`, used only to show where a paper construct lives in the code that the Racket kernel must match. The paper describes Cordis v4 (paper:6933); the vendored kernel is a v4 release candidate with local changes logged in `vendor/README.md`. Where the paper and the vendored code differ, the vendored code is the behavior to port and the paper is the specification of intent.

Notation used below (the PDF math is noisy, so it is restated here): `Γ` context type, `γ, δ` context states, `φ` accumulator, `f` forward map, `g, h` inverse, `e` effect function, `i` effect iterator, `Σ` coeffect context, `σ` a coeffect table, `k` key, `K` key set, `d` coeffect specification (declared dependencies), `p` coeffect provision (keys a component may provide), `n, m` fiber names, `π` parent, `τ` retirement flag, `θ` lifecycle state, `ω` committed view, `≃` observational equivalence, `∘` function composition (right operand runs first), `⋄` effect composition.

## Thesis and vocabulary

**Problem.** Static composition (function calls, imports, inheritance) is resolved before execution. Dynamic composition loads, unloads and reconfigures components while the program runs. The paper claims its formal basis is underdeveloped and that current practice falls back on restarting a process or a container (paper:103-113, 184-205).

**Two dimensions (§1.1).** Temporal composability: when a component is removed, every modification it made to the shared environment is reversed completely and safely; this needs tracking of every resource allocation, event registration and state mutation, and ordered reclamation. Spatial composability: components declare, discover and resolve dependencies on each other in a structured, checkable way; this needs management of dependency topology and coordination of lifecycles when dependencies change. Statically these reduce to lexical scoping (RAII, bracket) and import resolution. Dynamically, effects are long-lived and not lexically bounded, and dependencies appear, disappear or change identity during execution (paper:114-131).

**Motivating evidence (§1.2).** VSCode's extension host cannot unload one extension's code; `deactivate` only runs at host shutdown and separates disposal from creation. Of the top 100 extensions by install count (Marketplace data of June 9, 2026), 87 contain executable code and so need a host restart on removal, and only 7 declare `extensionDependencies` on non-built-in extensions; `getExtension(...).exports` is untyped (paper:136-165). Self-evolving agent harnesses are named as the case where both dimensions are indispensable: each self-modification is a dynamic composition, a restart discards process-local state, and a faulty self-modification can disable the process needed to recover (paper:166-183).

**Effect versus coeffect (§2).** An effect system annotates the result type of a judgment, `Γ ⊢ t : T^effect`, and describes what a computation does to its environment (monads; algebraic effects and handlers). A coeffect system annotates the context, `Γ^coeffect ⊢ t : T`, and describes what a computation requires from its environment (comonads; graded semirings). Both are static: effects are tracked in lexically fixed scopes and coeffect annotations are checked against contexts fixed before execution. The paper's move is to reify both so a runtime operates on them directly (paper:244-323).

**Revertible effect.** An effect is a function `Γ → Γ × (Γ → Γ)`: applied to the current context it returns the modified context and an explicit inverse. Returning the inverse to the runtime is what makes the effect trackable; supplying it is what makes it revertible. The inverse is a left inverse only (`g ∘ f`, never `f ∘ g`), and it is required to revert only at the state where the effect was applied (paper:343-365, 790-796).

**Reactive coeffect.** A component's dependencies are a specification (a set of keys). Every change of the context is classified against that specification as activating, deactivating or neutral, and that classification drives activation and deactivation. Provision of a dependency is itself a revertible effect on the coeffect context (paper:1290-1295, 1338-1346).

**Context paradigm.** The effect context and the coeffect context are one type, `Γ∞ = μΓ. Γ × (Γ → Γ) × Σ`, and every interaction between a component and its environment goes through it. A component's effect function may consist only of stages that are an operation on a value bound at a key, a provision of a binding at a key, or an instantiation of another component. Any shared location that is not bound at a key is outside the theory (paper:1627-1646, 1721-1755, 2849-2852).

**Component.** A triple `(d, p, e)`: coeffect specification `d` (keys read from the environment), coeffect provision `p` (keys it may install), and a witnessed effect iterator `e` that installs its effects and yields the inverses that withdraw them (Definition 48, paper:2867-2896).

**Fiber.** One instantiation of a component, a tuple `⟨d, p, e, π, σ, τ, θ⟩`: the component's three parts, the parent fiber or `root`, the fiber's own coeffect table (empty until it activates, a subset of `p`), a retirement flag, and a lifecycle state `Inactive | Reloading(i, g, ω) | Active(g, ω) | Unloading(g, ω)`. `i` is the remaining iterator, `g` the accumulator built so far, `ω : d → names` the committed view that maps each declared key to the fiber that provided it when the activation began (Definition 49, paper:2909-2957).

**Other terms.** Accumulator: the composite of the inverses of effects performed so far. Soundness invariant: `φ(γ) = γ0`. Witness: the proof obligation attached to an effect function (its inverse reverts it) or to a coeffect (its operations commute pairwise); both are unchecked at runtime. Realization: in-place (mutate and return a real inverse) or derived (return a fresh child context, inverse is identity, recovery is discarding the child). Realm: the indirection `key → realm → value` that lets the same key bind different values in different contexts. Target view: what a fiber's `ω` should be now, or `⊥` if it should not run. Quiescent state: every fiber is `Inactive` with target `⊥` or `Active` with `ω` equal to its target. Episode: a maximal interval in which a fiber is not `Inactive`. Orchestrator: the external party that inserts and retires fibers. Entry: the loader's declarative record of one fiber.

## Formal development

Every numbered item of §3 and §4 is listed. "Obliges" states what a kernel must do or what an author must guarantee. Items marked "proof device" impose nothing at runtime.

### §3.1 Revertible effects

- **Definition 1, twisted composition.** `(f1, g1) ∘ (f2, g2) = (f1 ∘ f2, g2 ∘ g1)`; pairs of context transformations form the monoid `T_Γ` with unit `(id, id)`. Obliges: when two effects are sequenced, their inverses compose in the opposite order.
- **Definition 2, effect context.** `∂Γ = Γ × (Γ → Γ)`, a pair `(γ, φ)` of current state and accumulator; the initial value is `(γ0, id)`; `∂²Γ = ∂(∂Γ)`. Obliges: each tracking scope keeps one accumulator beside the state it guards.
- **Definition 3, track.** `track(f, g)(γ, φ) = (f(γ), φ ∘ g)`. Obliges: registering an effect applies the forward action and pushes its inverse so that it runs before all earlier inverses.
- **Theorem 4.** `pr1 ∘ track(f, g) = f ∘ pr1`. Obliges: tracking must not change what the forward action does.
- **Theorem 5.** `track` is a monoid homomorphism: it maps `(id, id)` to `id` and twisted composites to composites. Obliges: tracking effects one at a time is the same as tracking their composite once.
- **Definition 6, recover.** `recover(γ, φ) = (φ(γ), id)`. Obliges: unloading applies the accumulator once and resets it to empty.
- **Theorem 7.** If `g(f(γ)) = γ` then `recover(track(f, g)(γ, φ)) = recover(γ, φ)`. From `(γ0, id)` every state reached by such steps satisfies the soundness invariant `φ(γ) = γ0`, and recovery returns `(γ0, id)`; equation (11) is the same for a sequence. Obliges: if each inverse reverts its own step at the state where it was applied, unloading restores the starting state.
- **Definition 8, effect function.** `E_Γ = Γ → Γ × (Γ → Γ)`; the witnessed form `E*_Γ` adds a proof that `(δ, g) = e(γ)` implies `g(δ) = γ`. The inverse may differ per state. Obliges: an effect callback returns its inverse at the point of application; the law is the author's obligation.
- **Definition 9, effect composition.** `(f ⋄ g)(γ) = let (δ, s) = g(γ); (ε, t) = f(δ) in (ε, s ∘ t)`. Obliges: `g` runs first, then `f`; the composite inverse runs `t` (the inverse of `f`) first, then `s`.
- **Theorem 10.** `(E_Γ, ⋄)` is a monoid with unit `η = γ ↦ (γ, id)`, and `(f, g) ↦ (γ ↦ (f(γ), g))` is a homomorphism from `T_Γ`. Obliges: an effect that does nothing and returns a no-op inverse is legal.
- **Theorem 11.** `E*_Γ` is a submonoid, and a pair with `g ∘ f = id` maps into it. Obliges: an effect assembled from correct atomic effects needs no hand-written inverse.
- **Definition 12, effect.** `effect(e)(γ, φ) = let (δ, g) = e(γ) in ((δ, φ ∘ g), track(g, pr1 ∘ e))`, of type `E_Γ → ∂Γ → ∂²Γ`. Obliges: `ctx.effect` both records the inverse in the owner's accumulator and returns a disposer; running the disposer is itself a tracked transformation one level up.
- **Theorem 13.** `effect(f) ⋄ effect(g) = effect(f ⋄ g)`. Obliges: nesting `effect` calls and composing callbacks give the same result.
- **Theorem 14.** With `e' = effect(e)`: `pr1 ∘ f' = f ∘ pr1` and `pr1 ∘ g' = g ∘ pr1`. Proof device: the lifted maps act on the state exactly as the unlifted ones.
- **Theorem 15.** For witnessed `e`, the lifted inverse returns `(γ, φ ∘ g ∘ f)`. The state is restored exactly; the accumulator is restored only if `g ∘ f = id` everywhere; in every case `(φ ∘ g ∘ f)(γ) = φ(γ)`. Obliges: disposing one effect early restores the state and leaves the owner's later unload correct. A kernel realizes this by making the disposer single-shot and skipping it at owner unload.
- **Theorem 16.** Effects `e1..en` in `E*` applied in order from `(γ0, id)` and reverted in reverse order: each revert restores the state its application ran against, and every intermediate state satisfies the soundness invariant. Obliges: disposers collected by one effect run last-in first-out.
- **Definition 17, effect iterator.** `I_Γ = μI. Γ → Γ × (Γ → Γ) × Maybe(I)`; each iteration yields a new context, an inverse and an optional continuation; the witnessed form `I*_Γ` holds every iteration to `g(δ) = γ`. Obliges: support effects that produce inverses one at a time (generators), with a usable stopping point between any two iterations.
- **Definition 18, effect-iter.** Runs the iterator recursively; the accumulator becomes `φ ∘ g1 ∘ … ∘ gk` and the returned inverse is `t ∘ r`. A plain effect function is the iterator whose first iteration yields `Nothing` (equation 19). The iterator is described as a reified delimited continuation, the structure `yield` exposes. Obliges: after stopping at boundary `k`, exactly the first `k` inverses are held; one API accepts both a single disposer and an iterator of disposers.

Criterion for local temporal composability (paper:1268-1282): for every sequence of effect functions one component applies, the accumulator recovers the starting context (Theorem 7) and reverse-order reverting gives each inverse the state it was built for (Theorem 16). Out-of-order reverting and interleaving with other components are not covered here; they need independence (§3.4).

### §3.2 Reactive coeffects

- **Definition 19, coeffect context.** `Σ = (k : K) ⇀ V_k`, a finite partial function from keys to typed values, with `σ(k)`, `σ[k ↦ v]`, `σ ∖ k`. Extension requires `k ∉ dom(σ)`; restriction requires `k ∈ dom(σ)`. A violated precondition is an error and no transition. Obliges: providing an already-provided key fails loudly and changes nothing.
- **Definition 20, get and set.** `get(k)(σ) = σ(k)`; `set(k, v)(σ) = (σ[k ↦ v], λσ'. σ' ∖ k)`. `set` is a witnessed effect function on `Σ`. Obliges: provision goes through the effect primitive, so withdrawal is automatic.
- **Satisfaction (equation 22, unnumbered).** `σ ⊧ d` iff every `k ∈ d` is in `dom(σ)`. Decidable; since all mutations of `σ` are effects, changes in satisfaction are detectable at each effect.
- **Definition 21, coeffect specification.** `D_Σ = Set(K)`. Obliges: a component declares its dependency keys as data, readable before it runs.
- **Definition 22, notify.** `notify_d(σ, σ')` is `activating` if `σ ⊭ d` and `σ' ⊧ d`, `deactivating` if `σ ⊧ d` and `σ' ⊭ d`, else `neutral`. Obliges: every table change re-evaluates every fiber that declares a changed key; a neutral change must have no effect.

Criterion for local spatial composability (paper:1398-1412): a component activates only at a state satisfying its specification, and every change is classified so a loss of satisfaction drives deactivation. Ordering against other components (withdraw only after dependents finished; bindings stay fixed while an activation runs) is deferred to §4.3.3.

- **Definition 23, realizations.** An effect function may be realized in place (mutate, return a real inverse) or derived (return a fresh context deriving from the input, inverse is identity, recovery discards the derived context). Obliges: `isolate` and `intercept` create child contexts and register nothing to undo.
- **Definition 24, isolation.** `Σ_iso = (K ⇀ R) × ((r : R) ⇀ V_r)`, a realm table `ρ` and a dependency table `σ`; a key outside `dom(ρ)` resolves to its own realm (`R ⊇ K`). Obliges: resolution is two-step, `k → ρ(k) → σ(ρ(k))`.
- **Definition 25.** `get(k)(ρ, σ) = σ(ρ(k))`; `set(k, v)` writes `σ[ρ(k) ↦ v]` with inverse `σ' ∖ ρ'(k)`; `isolate(k, r)(ρ, σ) = (ρ[k ↦ r], σ)`. `isolate` has no precondition and may reassign an already isolated key. Obliges: `isolate` changes only how the derived context resolves the key.
- **Definition 26, interception.** `Σ_inter = ((k : K) → M_k) × ((k : K) ⇀ (M_k → V_k))`: context-carried metadata `ι` (default the empty element `ε_k`) and providers that are functions from metadata to value. A specification becomes `D_inter = (k : K) ⇀ M_k`, assigning declared metadata per key. Each `M_k` is a monoid `(M_k, ⊕_k, ε_k)`. Obliges: `inject` is a map from key to per-key metadata, not only a set.
- **Definition 27.** `get(k, μ)(ι, σ) = σ(k)(μ ⊕_k ι(k))`; `intercept(k, ν)(ι, σ) = (ι[k ↦ ι(k) ⊕_k ν], σ)`. The merge is right-biased: context-carried metadata overrides the component's declaration, and newer interception overrides inherited interception. Obliges: an enclosing context can constrain how a component uses a dependency without touching the component or the provider, and without any reload.

### §3.3 The context paradigm

- **Definition 28, context type.** `Γ∞ = μΓ. Γ × (Γ → Γ) × Σ`: current state (recursive), this level's accumulator, the coeffect context. `effect` maps `E_Γ∞` to itself. Because the value family is unconstrained, any shared mutable state can be a dependency. Obliges: contexts form a tree; a parent aggregates the effects of its children.
- **Definition 29, coeffect at a key.** A pair `(V_k, A_k)` of value type and a set of coeffect operations. An operation `a : X_a → V_k ⇀ V_k × (V_k ⇀ V_k) × B_a` takes an argument and the value, and returns a new value, an inverse and an outcome. Its lift to `Σ` reads and writes only the binding at `k` (through the realm when isolated). Obliges: a service's mutating methods are revertible operations confined to that service's own state.
- **Definition 30, context-mediated iterators.** For `P ⊆ S ⊆ K`, the least set containing the unit iterator, operation stages (one operation at a key of `S`, continuation chosen by the outcome) and provision stages (`set` at a key of `P`). Obliges: an effect function may touch shared state only through declared keys; a hidden global (the example is an allocator counter the context does not carry) breaks membership until it is bound at a key.
- **Definition 31, tests and indistinguishability.** A test is a finite word of forward maps and yielded inverses of a key's operations; two values are indistinguishable when every test is defined at both or neither and yields equal outcomes. `≃_k` is this relation for `A_k`. Obliges: "restored" means "no operation of the key can tell the difference", not bitwise equality.
- **Lemma 32.** `≃_k` is an equivalence respected by every operation of `A_k`, and the coarsest such. Proof device, and a method: to relate two values, exhibit any respected equivalence that contains the pair.
- **Definition 33.** `σ ≃_S σ'` iff both bind the same keys of `S` and to `≃_k`-related values; states are related when their coeffect projections are. The subscript is dropped for `S = K`. State that no key binds is forgotten. Related states agree on satisfaction and on `notify`.
- **Definition 34.** `≃_S` extends to functions (related inputs give related outputs), products (componentwise) and `Maybe`, coinductively on recursive types. A map respects `≃_S` when it is related to itself.
- **Lemma 35.** On maps and iterators `≃_S` is a partial equivalence (symmetric, transitive). Proof device.
- **Definition 36.** `E^S_Γ`: an effect function that respects `≃_S` and whose witness reads `g(δ) ≃_S γ`. `E*_Γ` is `E^K_Γ`.
- **Definition 37.** `I^S_Γ`: the iterator analogue.
- **Lemma 38.** Every state equality of §3.1 holds with `=` replaced by `≃`, and every reachable accumulator respects `≃`. Obliges: tests of recovery compare through the service interface.
- **Lemma 39.** A context-mediated iterator lies in `I^S_Σ` for any `S` containing the keys at which its stages occur. Obliges nothing more: staying inside Definition 30 gives the witness.

### §3.4 Attaining independence

- **Definition 40.** `reach(i)`: `i` and all continuations it can reach. `M(i)`: the transformation monoid generated by every forward map and every yielded inverse in `reach(i)`. `len(i)`: the longest continuation chain.
- **Lemma 41.** Commutation of two monoids is settled on generators, and `M(e1 ⋄ e2) ⊆ ⟨M(e1) ∪ M(e2)⟩`. Proof device.
- **Definition 42, independence.** Iterators `i, j` are independent when (1) every transformation of one commutes with every transformation of the other, forward maps and inverses alike, and (2) applying a transformation of one does not change the inverse or continuation the other yields. A family is pairwise independent when every two distinct members are; self-independence means `M(i)` is commutative. This differs from `e1 ⋄ e2 = e2 ⋄ e1`.
- **Theorem 43.** Pairwise independent witnessed effects applied in order from `γ0`: applying their yielded inverses at the final state in any permutation reaches `γ0`. Obliges: when effects are independent, one component can be unloaded while later effects of others stay in place.
- **Definition 44.** Operations are independent when their lifts are independent at every pair of arguments and neither disturbs the outcome the other yields. A key is commutative when any two of its operations (including an operation with itself) are independent.
- **Theorem 45.** Operations at distinct keys are independent. Obliges nothing; it is why the obligation is per key.
- **Definition 46, witnessed coeffect.** A coeffect carries a third constituent: a proof that its key is commutative. From here on every coeffect is assumed witnessed. Obliges: the component that provides a key guarantees that key's operations commute. The recipe (paper:2702-2734): give each registration its own entry and identifier (routes, listeners; the same reason CRDT sets tag additions); do not publish outcomes callers do not need (allocator handles compared by no operation commute; "lowest free descriptor" does not); an ordered chain such as middleware is not commutative.
- **Theorem 47.** Context-mediated iterators `i1 ∈ I(S1, P1)` and `i2 ∈ I(S2, P2)` with `P1 ∩ S2 = P2 ∩ S1 = ∅` and commutative shared keys are independent. Obliges: with witnessed keys, the only check left for a pair of components is that neither provides a key the other touches.

Division of labor stated at paper:2836-2848: commuting work is carried by effects (any order of revert); order-sensitive work is carried by coeffects, imposed either inside one component by its LIFO accumulator or across components by a declared dependency.

### §4 items (rules and narrative are in the next section)

- **Definition 48, component.** `C_Γ = (d : D_Γ) × (p : P_Γ) × I^{d∪p}_Γ`; `P_Γ = Set(K)`. Obliges: a plugin declares both what it injects and what it may provide; its effects install bindings only at keys of `p`.
- **Definition 49, fiber.** As in the vocabulary section; `installed_n(γ)` iff `θ_n ≠ Inactive`. Obliges: fiber state includes the remaining iterator, the accumulator and the committed view.
- **Definition 50, registry.** `F_γ : names ⇀ fibers`, finite, parent pointers form a tree rooted at `root`. The coeffect context is derived: `σ_γ` is the union of the tables of `Active` fibers only; `provider_k(γ)` is the one `Active` fiber whose table holds `k`. Names are atoms compared only by equality. Obliges: a binding counts as available only while its provider is `Active`; a `Reloading` or `Unloading` fiber provides nothing.
- **Definition 51.** `σ^S_γ` is the union of every fiber's table restricted to `S`, over all fibers regardless of state; this is the projection witnesses are read at.
- **Definition 52, instantiation.** An iteration may instantiate a component: its forward step is O-Insert with `π = n`, and its inverse is O-Retire of the new fiber (retire, not remove, because an inverse must always be applicable). Obliges: creating a child plugin is a tracked effect of the parent, so unloading a parent retires its children.
- **Definition 53, target view and quiescence.** `target_n(γ) = ⊥` if `τ_n` or `γ ⊭ d_n`, else the map `k ∈ d_n ↦ provider_k(γ)`. `quiet(γ)`: every `Inactive` fiber has target `⊥` and every `Active` fiber has `ω_n = target_n(γ)`; any fiber in a transition makes the state non-quiescent.
- **Definition 54, relied.** `relied_n(γ)` iff some other installed fiber `m` has `ω_m(k) = n` for a declared key `k`.
- **Definition 55, confinement.** A map is confined to `n` when it writes only `σ_n` and values (not domains) at keys of `d_n` in other fibers' tables, never changes the registry domain or control fields, and reads only those same parts. Instantiation is the one exception.
- **Definition 56.** Stages lift from `Σ` to `Γ` along the coeffect projection; `I^A_Γ(n)` contains the unit, lifted operation stages at keys of `d_n ∪ p_n`, lifted provision stages at keys of `p_n`, and instantiations. Every fiber's effect function must lie in it.
- **Lemma 57.** A member of `I^A_Γ(n)` is confined to `n` and is witnessed at `≃_{d_n ∪ p_n}`. Obliges: a plugin must not branch on another fiber's lifecycle state or on a key it did not declare.
- **Definition 58.** Step indexing: `step_t = r(n)`; sequences start from an empty registry; episode of `n` is a maximal interval with `installed`; each step factors as `γ_{t+1} = edit_t(Ψ_t(γ_t))`, where `Ψ_t` is the state map (`pr1 ∘ i` at L-Iter, L-Finish and a landing L-Divert; `g` at L-Unload; `id` otherwise) and `edit_t` writes control fields. Whole-state `≃` (equation 54) adds agreement on registry domain and all control fields.
- **Lemma 59, table lookups.** (1) A table changes only inside a `Ψ_t`, at the acting fiber or as values at keys the acting fiber declares. (2) `ω_n` is created only by L-Begin and destroyed only by L-Unload, so it is constant over an episode. (3) An accumulator is applied only by L-Unload of its own fiber. (4) `installed_n` rises only at L-Begin and falls only at L-Unload. (5) `π, d, p, e` are written once at insertion; `τ` is monotone, set only to true and only by O-Retire.
- **Lemma 60, ≃-invariance.** Rules apply at `≃`-related states alike and lead to `≃`-related states. Obliges: the scheduler may not consult anything outside control fields and table domains.
- **Lemma 61, equivariance.** Renaming fibers by a bijection commutes with every rule. Obliges: no behavior may depend on the numeric value of a fiber id.
- **Lemma 62, vestigial entries.** A fiber that is retired, `Inactive`, has an empty table and no children is invisible to every rule acting on other fibers, except that it blocks reuse of its name and of its provision keys by O-Insert.
- **Definition 63, well-formed registry.** (1) every parent is present or `root`; (2) provisions of distinct fibers are disjoint; (3) an installed fiber's `ω` is total on `d` and names present fibers; (4) every fiber named by an installed fiber's `ω` is installed.
- **Theorem 64, preservation.** Every rule preserves well-formedness.
- **Definition 65.** Independence read up to `≃`; fibers are entangled when one's provision meets the other's `d ∪ p`; a sequence is pairwise independent when every two names are independent or entangled with commutative shared keys.
- **Lemma 66.** Every sequence of steps is pairwise independent (given witnessed coeffects and Definition 56).
- **Lemma 67, entangled steps.** While a consumer's episode is open, its provider takes only steps with `Ψ = id`; a consumer's maps commute with its provider's accumulator at the states that arise; while a fiber is `Reloading`, every fiber entangled with it takes only steps with `Ψ = id`.
- **Theorem 68, recovery exactness.** For `u` in an episode of `n` opened at `b`, `g^u_n(γ_u) ≃_K (Ψ_{t_l} ∘ … ∘ Ψ_{t_1})(γ_b)`, where the `t_j` are the steps in `[b, u)` taken by other fibers.
- **Corollary 69, terminal recovery.** When the episode closes at `u`, `γ_{u+1} ≃_K (Ψ_{t_l} ∘ … ∘ Ψ_{t_1})(γ_b)`, and `σ_n` is empty.
- **Theorem 70, ordering.** L-Begin of `m` only where `γ ⊧ d_m`. If `m` resolved `k` to `n` for an episode `[b', u']` inside `n`'s episode `[b, u]`: (1) `ω_m(k) = n` throughout; (2) `b < b'` and, if `n`'s episode closes, `u' < u`; (3) `k` stays in `n`'s table throughout and its value moves only by operations at `k` of fibers that declare `k`.
- **Theorem 71, resolution coherence.** A fiber is `Reloading` on an initial interval of its episode; every L-Iter and L-Finish in it has `target = ω`; it leaves either by L-Finish into `Active(−, ω)` or by L-Divert, after which the episode closes and Corollary 69 holds.
- **Definition 72, precedence.** `n ≺ m` iff `p_n ∩ d_m ≠ ∅`.
- **Theorem 73, progress.** Assuming `≺` acyclic, `len(e_n) ≤ K` for all `n` (here `K` is a numeric bound on iterator length, not the key set), and finitely many names: a non-quiescent state always admits a lifecycle rule; `S(n) ≤ (K + 3)(V(n) + 1)` where `S` counts steps on `n` and `V` counts changes of its target; every maximal lifecycle sequence ends quiescent.
- **Definition 74, support.** `m ⊲ n` iff `m ≺ n` or `π_n = m`. The support set `A` is defined recursively: `n ∈ A` iff not retired, parent is `root` or in `A`, and every declared key is in the provision of some member of `A`.
- **Lemma 75.** With `≺` acyclic and a reachable state, `⊲` is well founded and `A` is the unique solution, a function of `τ, π, d, p` only.
- **Definition 76, total on provision.** A component whose finished activation has installed every key of `p`.
- **Lemma 77.** With `≺` acyclic, a quiescent state and total components, `A` equals the set of `Active` fibers.
- **Lemma 78, transposition.** Two adjacent activation steps of distinct independent fibers can be swapped without changing the result; an activation step and an orchestration step on another fiber (not instantiated by that step) can be swapped.
- **Lemma 79, deletion.** A closed episode of a `⊲`-maximal fiber, with the steps of fibers it instantiated, can be deleted from a sequence without changing the quiescent endpoint up to `≃_K`.
- **Theorem 80, confluence.** Given a quiescent endpoint and total components: (1) the endpoint is reached by a canonical sequence that performs the same orchestration steps in their original order (those on orchestrator-inserted fibers before every lifecycle step, those on instantiated fibers after the instantiating step) and exactly one episode per member of `A`, in an order linearizing `⊲`; (2) any two sequences with the same orchestration steps reach states related by `≃` after renaming. With Theorem 73, the lifecycle relation has unique normal forms.

## The calculus

### Syntax and derived notions

A state `γ` carries a registry `F_γ` of fibers plus whatever no fiber table names. Fibers are the tuples of Definition 49. The coeffect context is not stored; it is computed as the union of `Active` fibers' tables. Two relations are generated by nine rules: orchestration `γ ⇒ δ` (prefix O-, an action the orchestrator may take when the premises hold) and lifecycle `γ → δ` (prefix L-, a step the system takes unprompted when the premises hold). The rules name no scheduler; any interleaving is a valid sequence, so every theorem holds for every scheduling policy (paper:3442-3446).

### The nine rules (paper:3131-3176, 3304-3394)

```
O-Insert  n ∉ dom(F)   π ∈ dom(F) ∪ {root}   (d,p,e) ∈ C   ∀m ∈ dom(F). p ∩ p_m = ∅
          γ ⇒ γ[n ↦ ⟨d, p, e, π, ∅, ⊥, Inactive⟩]
O-Retire  n ∈ dom(F)
          γ ⇒ γ[τ_n ↦ ⊤]
O-Remove  τ_n = ⊤   θ_n = Inactive   σ_n = ∅   ∀m. π_m ≠ n
          γ ⇒ γ ∖ n
L-Begin   θ_n = Inactive   ω = target_n(γ) ≠ ⊥
          γ → γ[θ_n ↦ Reloading(e_n, id, ω)]
L-Iter    θ_n = Reloading(i, g, ω)   target_n(γ) = ω   i(γ) = (δ, h, Just i')
          γ → δ[θ_n ↦ Reloading(i', g ∘ h, ω)]
L-Finish  θ_n = Reloading(i, g, ω)   target_n(γ) = ω   i(γ) = (δ, h, Nothing)
          γ → δ[θ_n ↦ Active(g ∘ h, ω)]
L-Divert  θ_n = Reloading(i, g, ω)   target_n(γ) ≠ ω   (δ, h) = (γ, id)  or  i(γ) = (δ, h, _)
          γ → δ[θ_n ↦ Unloading(g ∘ h, ω)]
L-Leave   θ_n = Active(g, ω)   target_n(γ) ≠ ω
          γ → γ[θ_n ↦ Unloading(g, ω)]
L-Unload  θ_n = Unloading(g, ω)   ¬relied_n(γ)   g(γ) = δ
          γ → δ[θ_n ↦ Inactive]
```

### State machine (Figure 1, Table 1)

```
(absent) --O-Insert--> Inactive --L-Begin--> Reloading --L-Finish--> Active
Inactive --O-Remove--> (absent)             Reloading --L-Iter--> Reloading
Reloading --L-Divert--> Unloading           Active --L-Leave--> Unloading
Unloading --L-Unload--> Inactive            O-Retire: self-loop at every state, sets τ only
```

Points an implementer must reproduce:

1. The orchestrator never sets a lifecycle state. It inserts and retires; the lifecycle rules do the rest (paper:3143-3144).
2. Retire and remove are separate. Removing an `Active` fiber would discard its accumulator and leak its effects. O-Remove requires retired, `Inactive`, empty table, and no children, so children are removed before parents (paper:3177-3190).
3. O-Insert enforces the single-provider rule: no new fiber whose provision overlaps an existing fiber's provision. In the realm reading (§4.4) this becomes "disjoint within a realm". A component with a non-empty provision therefore has at most one fiber per realm.
4. Activation is one run of the effect iterator: L-Begin commits the view, L-Iter takes one iteration, L-Finish takes the last. Each new inverse `h` is composed as `g ∘ h`, so the accumulator runs inverses last-in first-out.
5. Deactivation is split into decision and act. L-Leave (from `Active`) and L-Divert (from `Reloading`) only mark the fiber `Unloading`; this removes its table from `σ_γ` immediately, so dependents see their target change, while every committed view and every binding stays in place. L-Unload is the only rule that applies an accumulator, and it is guarded by `¬relied_n`: it waits until no installed fiber's committed view names `n`. The stated reason is that a consumer's teardown may need the dependency being withdrawn, for example a connection pool returning connections to its provider (paper:3341-3351).
6. L-Divert never routes through `Active`, so a fiber that is already leaving never provides for one step. It has two alternatives: abort the pending iteration (`(δ, h) = (γ, id)`) or let it land and keep its inverse. An asynchronous host can only offer the landing alternative.
7. The guard is per binding, not per fiber and not along the parent tree. A parent may run its accumulator while a child is still `Unloading`; parent and child are ordered only by the retire cascade and by independence (paper:3416-3441).
8. The guard cannot deadlock: once `n` is `Unloading` it provides nothing, so every consumer committed to `n` has a target different from its view and is itself on the way out; with `≺` acyclic the chain of waits ends (Theorem 73).
9. Both directions of change take the same exit: a dependency that vanished (`target = ⊥`) and one that was replaced by another fiber (`target` names a different provider) are both "target ≠ ω". Recording the provider, not the value, is what makes replacement by an equal value visible (paper:3282-3294).

### Confinement (§4.2.3)

An effect function may write its own table and the values at keys it declared in the provider's table, may read those same parts, and may instantiate components. It may not read or write any other table, any control field of any fiber, or state that no key binds. This is what lets Table 1 be a complete list of writes.

### Metatheory: guarantees and side conditions

| Result | Guarantees | Side conditions |
|---|---|---|
| Preservation (Thm 64) | The four well-formedness clauses hold after every step. A freed name can be reused; a fiber can be removed as soon as it is `Inactive`. | None beyond the rules. The guard on L-Unload is what keeps committed views from naming absent fibers. |
| Temporal composability (Lemma 66, Lemma 67, Thm 68, Cor 69) | Running a fiber's accumulator withdraws that fiber's contribution and nothing else, whatever other fibers did in between; after unload its own table is empty. | Every effect function is context-mediated (Def 56); every effect inverse is witnessed; every key is commutative (Def 46). All three are author obligations, unchecked. Equality is up to `≃_K`: a monotone allocator is not rewound, heap layout is not restored, a sent message stays sent. If `n` instantiated fibers that took steps in the interval, "as if `n` never began" must discount them. |
| Spatial composability, ordering (Thm 70) | Activation only when all declared keys are provided; a provider's episode strictly contains each consumer episode that resolved to it; the binding stays present and is changed only by operations of fibers declaring the key. | None beyond the rules. |
| Spatial composability, coherence (Thm 71) | No activation iteration runs against a resolution other than the committed one, except the single landing iteration of an L-Divert, whose effect is then withdrawn by the unload that must follow. | A host restricted to the landing alternative gets the disjunction, not a per-step guarantee. |
| Progress (Thm 73) | No deadlock; step bound `S(n) ≤ (K + 3)(V(n) + 1)`; every maximal lifecycle sequence ends quiescent. | `≺` acyclic (an assumption; a component that declares a key it provides has `n ≺ n`); every iterator has bounded length; finitely many fiber names, which holds when no component can instantiate itself without bound, however indirectly. Proved without the aborting alternative of L-Divert. |
| Confluence (Thm 80) | The quiescent state depends only on the orchestration inputs, not on schedule or history, and equals the state reached by loading each supported fiber once in dependency order. | Reaches a quiescent state; `≺` acyclic; every component total on its provision (Def 76); compared up to `≃` and renaming of fiber names. It is a statement about the final state, not about emissions made on the way. Failed fibers are excluded. |

### Extensions (§4.4), each realized by the implementation

- **Asynchrony.** Iterations and inverses yield futures. The host is inertial: it takes only the landing alternative of L-Divert, so a fiber whose target changes during an iteration deactivates after that iteration lands, holding its inverse. All results still hold because they quantify over all sequences. An inverse in flight needs no extra rule. A deactivation may chain directly into an activation (the accumulator runs, then L-Begin).
- **Failure.** An iteration may raise instead of yielding: `Γ → Either(Ξ, Γ × (Γ → Γ) × Maybe(I))`. A raise leaves `Reloading` like an aborting L-Divert with no target premise: the fiber goes to `Unloading` with the accumulator built so far, reaches `Inactive` having installed nothing, and the error is recorded on the fiber as an outcome. L-Begin requires an error-free fiber, so a failed effect function is not retried against an unchanged environment; `quiet` admits a failed fiber whatever its target; the failure does not propagate to the parent or siblings. A retry is a revision (remove and reinsert). Confluence excludes failed fibers because whether an iteration raises can depend on the schedule.
- **Isolation.** For realms fixed at insertion, use the key set `K × R`: a fiber under realm table `ρ` declares and provides pairs `(k, ρ(k))`; O-Insert's disjointness is then per realm; the shared realm is the diagonal `(k, k)`. Calling `isolate` on a running fiber changes its interface, so it is a revision. Interception needs no extension: no rule reads metadata.
- **Configuration.** Configuration lives inside `e`; the same component with two payloads is two components. Revising a running fiber (new configuration, new realms, disable, re-enable) is a composite: disabling is O-Retire; anything else is retire, wait for deactivation, remove (children first), reinsert at the same name. Re-enabling never writes `τ` back to false, because Theorem 80 relies on retirement being permanent and because a fiber un-retired after its creator's accumulator ran would activate with its creator gone. The implementation keeps the same split: the entry is the identity that survives revision, and a fiber is the identity of one enablement. The loader's shorter routes (pass new config to a component that decides whether to reload; move a realm without reloading its provider) are justified only by reaching the same endpoint.

## Implementation section

§5 presents Cordis as a "meta-framework": it prescribes no domain and supplies only dynamic composition semantics, in three tiers: core library, component loader, application frameworks such as Koishi (paper:6063-6071).

### Table 2, theory to runtime (paper:6080-6150)

| Theory | Runtime name in the paper |
|---|---|
| `Γ∞` | `ctx`, the first-class context |
| `E_Γ`, `I_Γ` | effect callback returning or yielding inverses |
| `effect(e)` | `ctx.effect(callback)` |
| `Σ`, `Σ_iso`, `Σ_inter` | symbol-keyed slots `ctx[@@store]`, `ctx[@@isolate]`, `ctx[@@intercept]` |
| `get`, `set`, `isolate`, `intercept` | `ctx.get(key)`, `ctx.set(key, value)`, `ctx.isolate(key, realm)`, `ctx.intercept(key, metadata)` |
| fiber, registry domain, name | `fiber`, enumerated through `ctx.registry`, `fiber.uid` |
| `d`, `p`, `e` | `fiber.inject`, the component's `provide`, `fiber.apply` |
| `π` | `fiber.parent.fiber.uid` |
| derived realization | `fiber.ctx`, the child context the fiber runs in |
| `θ` | `fiber.state`; `LOADING` is `Reloading`; `FAILED` carries the error outcome |
| accumulator `g` | `fiber.dispose` |
| `ω` | `fiber.committed` |
| `provider_k(γ)` | an `Impl` whose provider fiber is `ACTIVE` |
| `target` | `fiber.target`, recomputed by `refresh`; `⊥` is `INACTIVE` |
| future, inertia | `fiber.inertia`, handle of the transition in flight |
| O-Insert, O-Retire | `ctx.use` and the inverse of its callback |
| O-Remove | fiber dropped from its runtime, `uid` cleared |
| L-Begin, L-Iter, L-Finish | the iteration loop of `execute` |
| L-Divert | the guard failing at an iteration boundary, or `reload` chaining into `unload` |
| L-Leave | `refresh` marking the fiber `UNLOADING` |
| L-Unload and its guard | `unload`; `unload` awaiting the notified dependents |
| failure | the error recorded on the fiber, target set to `⊥` |

### Effect tracking (§5.1.1, Algorithm 1)

Every context mutation goes through `ctx.effect`: provision, instantiation and all other mutating operations reduce to it. It accepts a plain effect function or an iterator. The runtime does not check either witness (paper:6177-6186).

```
async execute(callback, guard):
  iter ← callback(); inverse ← id
  while guard():
    (value, done) ← await iter.next()
    if value: inverse ← value ∘ inverse      # new inverse runs first
    if done: break
  return inverse

effect(ctx, callback):
  armed ← true
  task ← execute(callback, () ↦ armed)
  async dispose():
    if not armed: return
    armed ← false
    recover ← await task; recover()
  ctx.dispose ← dispose ∘ ctx.dispose
  return dispose
```

Three properties to keep: the guard is consulted before every iteration, so a stop keeps only the inverses collected so far; the returned disposer is single-shot (a second run would apply an inverse at a state no application produced); the disposer is added to the enclosing context's accumulator, so a child effect's inverse is an effect of the parent. The component level reuses `execute` with a guard that tests whether `fiber.target` is unchanged.

### Coeffect operations (§5.1.2, Algorithms 2 and 3)

`get(ctx, key)` reads `realm ← ctx[@@isolate][key]` then `ctx[@@store][realm]`. `set(ctx, key, value)` is `ctx.effect` of a callback that writes `ctx[@@store][realm] ← value`, calls `notify(ctx, [key])`, and returns an inverse that deletes `ctx[@@store][realm]` and calls `notify(ctx, [key])` again; the realm is captured at provision time. `notify(ctx, keys)` visits every live fiber, and for the first changed key that is in `fiber.inject` and for which `fiber.ctx[@@isolate][key] = ctx[@@isolate][key]`, calls `refresh(fiber)`; it returns the set of fibers it refreshed so a caller can wait for them. `refresh` is idempotent, which is how a neutral change is made harmless. `refresh` resolves each declared key against an active provider, not against the store alone, so a provider that entered `UNLOADING` already counts as gone while its bindings are still present. `ctx.isolate(key, realm)` derives a child context with the realm overridden, defaulting to a fresh symbol. `ctx.intercept(key, metadata)` derives a child context whose metadata for `key` is the inherited metadata merged with the new, the new taking priority.

### Component lifecycle (§5.1.3, Algorithms 4 and 5)

```
use(ctx, component, config):
  fiber ← Fiber(parent: ctx, inject: component.inject)
  fiber.ctx ← ctx[fiber ↦ fiber]
  fiber.apply ← () ↦ component.apply(fiber.ctx, config)
  ctx.effect(() ↦ { refresh(fiber); return () ↦ { fiber.target ← ⊥; unload(fiber) } })
  return fiber

refresh(fiber):
  target ← target(γ, n)
  if target = fiber.target: return
  fiber.target ← target
  if fiber.inertia: return
  if target ≠ ⊥: fiber.state ← LOADING;   fiber.inertia ← create_task(reload(fiber))
  else:          fiber.state ← UNLOADING; fiber.inertia ← create_task(unload(fiber))

async reload(fiber):
  target0 ← fiber.target
  fiber.committed ← resolve(fiber.inject)
  recover ← await execute(fiber.apply, () ↦ fiber.target = target0)
  fiber.dispose ← recover ∘ fiber.dispose
  if fiber.target = target0: fiber.state ← ACTIVE; notify(fiber.ctx, provided(fiber)); fiber.inertia ← null
  else:                      fiber.state ← UNLOADING; fiber.inertia ← create_task(unload(fiber))

async unload(fiber):
  await all(notify(fiber.ctx, provided(fiber)).map(f ↦ f.await()))   # guard: drain dependents
  await fiber.dispose(); fiber.dispose ← id; fiber.committed ← ⊥
  if fiber.target = ⊥: fiber.state ← INACTIVE; fiber.inertia ← null
  else:                fiber.state ← LOADING;  fiber.inertia ← create_task(reload(fiber))
```

Stated facts: `fiber.target` is a digest built by resolving each declared key and tupling the uid of the provider; uids are fresh and never reused, so one comparison detects replacement even by an equal value. A provider that overwrites its own binding in place is not observed; to propagate, withdraw and reinstall. Two levels of checking exist: at transition completion (inertial chaining between `reload` and `unload`) and at each iteration boundary (partial rollback inside one transition). Three placements carry Theorem 70: the view is committed at the start of `reload` and discarded only after every inverse ran; `refresh` sets `UNLOADING` before the unload task is created (the L-Leave step); `unload` waits for notified dependents before the whole recovery, not inside one inverse, "since `fiber.dispose` initiates a fiber's effects concurrently" (paper:6499-6501). `create_task` is written explicitly because hosts with lazy scheduling (Python coroutines, Rust futures) must spawn the task (footnote, paper:6431-6434).

One inconsistency in the paper to be aware of: Algorithm 5 is described as reverting "all tracked effects in LIFO order" (paper:6390), while the remark above says the fiber's effects are disposed concurrently. The vendored kernel runs the fiber's top-level disposers concurrently with `Promise.all` and keeps reverse order only inside one effect (`vendor/cordis/src/fiber.ts:720-730` and `:437`). The port must follow the kernel recon note on this point, not the pseudo-code.

### Context access (§5.1.4, Algorithm 6)

Property access `ctx[key]` is mediated (a `Proxy` get trap in TypeScript). Resolution walks the fiber chain upward from the accessing context: return `fiber.committed[key]` at the first fiber whose committed view binds the key; throw `INACTIVE_ACCESS` if a fiber on the way declares the key in `inject` but has not committed it; throw `UNDECLARED_ACCESS` at the root. `ctx.get(key)` by contrast is a store lookup that never fails. Reading the committed view, not the store, is what keeps a dependency readable during a teardown caused by that dependency leaving.

### Cross-check against the vendored kernel (verified lines)

| Paper | Vendored code |
|---|---|
| Lifecycle states | `FiberState { PENDING, LOADING, ACTIVE, FAILED, DISPOSED, UNLOADING }` at `vendor/cordis/src/fiber.ts:147-154`. The paper's `INACTIVE` is `PENDING`; `DISPOSED` is `uid === null` (`fiber.ts:580-585`). |
| `fiber.target` digest | `_runner.epoch`, a string: `_revision` followed by `:` and `impl.uid` per `inject` key, or the `INACTIVE` constant when any key is unresolved (`fiber.ts:617-628`). The uid is the provision's (`++_implCounter`, `vendor/cordis/src/reflect.ts:302`), not the fiber's, so withdrawing and reinstalling a binding reloads dependents. `restart()` bumps `_revision` (`fiber.ts:768-774`). |
| `refresh` | `_setEpoch` (`fiber.ts:630-646`); a failed fiber ignores epoch changes until `update()` clears `_error` (`fiber.ts:633-634`, `:790`). |
| `reload` | `_reload` (`fiber.ts:681-710`): commits `committed = { ...this._store }`, registers itself in each provider `impl.dependents`, records `_error` and sets the epoch to `INACTIVE` on a throw, chains to `_unload` if the epoch moved. |
| `unload` and guard | `_unload` (`fiber.ts:712-746`): waits while any own provision has dependents, runs disposers, releases its providers, clears `committed`, chains to `_reload` if the epoch is not `INACTIVE`. The guard uses per-provision dependent sets instead of awaiting the fibers returned by `notify`. |
| `ctx.effect` | `Fiber.effect` (`fiber.ts:421-567`): per-effect disposer list run in reverse (`:437`), single-shot disposer, and local hardening that rejects new effects while the owner is `UNLOADING` (`:426-428`, `vendor/README.md` V6). |
| iteration guard | Async iterators check `runner.epoch !== oldEpoch` before each `next()` (`fiber.ts:395-399`). Synchronous iterators are drained without a guard check (`fiber.ts:381-388`). |
| `ctx.set` | `ReflectService.provide` (`reflect.ts:292-327`): default realm `Symbol(name)` on the root, error `service "<name>" has been registered at <fiber>` on a second provision in one realm, notification only when the owner is `ACTIVE`, and an inverse that deletes, notifies, then waits for dependents. |
| `ctx.get` | `ReflectService.get` and `_getImpl` (`reflect.ts:247-257`); strict mode returns only bindings whose provider is `ACTIVE`. |
| `notify` | `ReflectService.notify` (`reflect.ts:335`), default filter "same realm symbol". State changes notify only on transitions into or out of `ACTIVE` (`fiber.ts:594-600`). |
| Algorithm 6 | Proxy get trap (`reflect.ts:152-180`). Messages: `cannot get property "<prop>" without inject` and `cannot get required service "<prop>" in inactive context`. Beyond the paper: a fiber's own provisions in the same realm are readable, the upward walk stops when the parent resolves the key in a different realm, and a context with no plugin runtime keeps unchecked access. |
| `ctx.use` | `ctx.plugin()`; the child's disposer is an effect of the parent fiber labeled `ctx.plugin()` (`fiber.ts:271-303`). |
| `isolate`, `intercept` | `vendor/cordis/src/context.ts:121-125` and `:141-145`; both derive a child context whose table prototype-inherits from the parent's. The `⊕` merge is done at consumption by `Service[symbols.resolveConfig](base, head)` (`vendor/cordis/src/service.ts:86-102`): it collects the own entries along the prototype chain, ancestors first, puts `base` before them and `head` after them, and merges with the service's `Config.merge` or `Object.assign`, so later entries win. The fiber constructor writes each non-null `inject` value as the innermost entry (`fiber.ts:242-249`). That makes the component-declared value win over an enclosing context's interception, which reads as the opposite of the paper's "context-carried metadata takes priority" (paper:1609-1615). The port must follow the code; the kernel recon note should confirm the order. |

### Component loader (§5.2)

**Entries (Definition 81).** An entry declares one fiber and records `id` (stable identifier, the reconciliation key in its group's child list), `url` (component module to instantiate), `isolate` (isolation annotation on the entry's context), `intercept` (interception annotation), `config` (bound into the component to form `apply`), `disabled` (administratively off). The binding is two-way: the loader adjusts the fiber when fields change, and a component that revises its own configuration or disables itself has the change written back to its entry. An entry is a faithful specification because the support set reads only `τ` (from `disabled`), `π` (the entry's parent in the tree), and `d`, `p` (declared by the component `url` selects). Entries form a configuration tree. `@cordisjs/group` takes a list of child entries as its config; `@cordisjs/include` loads an external YAML or JSON file and grafts its entries as a subtree. Both are ordinary components built on instantiation, so nested trees stay inside the calculus.

**Reconciliation.** The loader reconciles incrementally, justified by four results: Theorem 80 (the quiescent state is a function of the final configuration), Theorem 73 (the system does quiesce, so reconciliation is complete once instantiations and retirements are issued), Corollary 69 (rebuilding one entry leaves the others as they were), Theorem 70 (entries can be instantiated together with no load order; dependencies constrain activation, not module fetching, so modules load concurrently). Per-field dispatch: `id` or `url` changed, rebuild the entry; `isolate`, reassign realms (Algorithm 7); `intercept`, update in place with no reload; `config`, hand to the component, which decides (typically diff and reload only on a material change), and for a group apply a keyed diff over child ids that creates, removes or updates children recursively; `disabled`, unload when set and reload when cleared.

**Managed realms.** `isolate: true` for a key selects a local realm private to the entry, tagged by its id, that moves with the entry. A string selects a global realm shared by every entry naming that string. A realm is discarded when no entry names it. Reassignment must decide whether the entry itself is the provider at a changed key, when a realm symbol may be shared by several fibers. The loader uses delimiters: one symbol `δ_k` per key, under which a context stores a tag that its descendants inherit and that is drawn fresh at each reassignment.

```
patch_isolation(entry, ρ'):
  ρ ← entry.ctx[@@isolate]; store ← entry.ctx[@@store]
  Δ ← { k | ρ(k) ≠ ρ'(k) }
  for k in Δ:
    entry.ctx[δ_k] ← fresh tag
    diff[k] ← (ρ(k), ρ'(k), entry.ctx[δ_k], store[ρ(k)].fiber.ctx[δ_k])
  entry.ctx[@@isolate] ← ρ'
  reload(entry.fiber)
  for k in Δ:
    (s1, s2, d1, d2) ← diff[k]
    if d1 = d2 and store[s1] and not store[s2]: store[s2] ← store[s1]; delete store[s1]
  affected(fiber, k): (s1, s2, d1, d2) ← diff[k]
    return fiber.ctx[@@isolate][k] ∈ {s1, s2} and (fiber.ctx[δ_k] = d1) ≠ (d2 = d1)
  notify(entry.ctx, Δ, affected)
```

The binding moves to the new realm exactly when the provider was derived from the entry's context. A dependent is notified exactly when "derived from the entry's context" differs between it and the provider, restricted to dependents resolving the key in one of the two realms (paper:6732-6767).

**Hot module replacement (§5.2.2).** A fiber already bounds all of a component's effects, so a module that is a component is replaced by disposing its fiber and instantiating a new one from the reloaded module, with no developer-annotated acceptance boundary. `@cordisjs/hmr` works in three phases. Classification (Algorithm 8): inputs are `stashed` (changed file URLs) and `externals` (modules that force a full restart); start with `accepted = stashed`, `declined = externals`, `pending` = the imports of stashed files not yet classified; iterate to a fixed point: a pending module with an accepted import becomes accepted, one whose imports are all declined becomes declined, otherwise its unclassified imports join `pending`; what remains (import cycles) is declined. Stale-entry detection (Algorithm 9): for each entry collect transitive imports of `entry.url`, not crossing declined modules; the entry is stale if that set meets `accepted`, and the set is then added to `accepted`. Transactional reload (Algorithm 10): invalidate caches of accepted modules keeping a backup; for each stale entry dispose its fiber and `ctx.use(import(entry.url), entry.config)`; on any error restore the caches, rebuild every stale entry from `backup[entry.url]`, and rethrow. On Node this means clearing both the ES-module and CommonJS caches (footnote, paper:6930-6931). The algorithms are transcribed as the paper prints them; the vendored `hmr` package and the DSH `packages/boot/hmr` replacement are specified in recon 02, and the port follows that code where it differs.

### Case study: Koishi (§5.3)

Koishi is a chatbot framework on Cordis with over 4,000 community plugins after four years; it currently runs Cordis v3, while the paper presents v4. Claims: the model is expressive (the server-side bot is entirely plugins over the context primitives) and general (the web console is a second, independent Cordis application in the browser); plugin authors get ordered cleanup of context-mediated effects without writing an uninstall path; the ecosystem has a real dependency topology (adapters, database drivers, feature plugins) and reconfiguring a provider reactivates only dependents whose resolved dependency changed, while a plugin with a missing dependency stays inactive without erroring. Threats to validity: one ecosystem, one host language, observational; overhead and productivity are unmeasured.

## Discussion and limits

**System boundary (§6.1).** A location is inside the boundary when the system can modify it exclusively and can restore the state before the modification; operations on it are tracked and revertible. Otherwise it is outside; an operation on it acts as identity on `Γ` and is neither tracked nor reverted. The boundary is per location, not per medium: a memory region or file is inside when only the system writes it. A coeffect moves the boundary by reifying an external location behind a set of operations that each supply an inverse; whether that is worth it is a cost per access. Operations reaching outside have two stages: acquisition installs a record inside the boundary (`open`/`close`, `malloc`/`free`, `fork`/`kill`) and is a revertible effect; emission pushes data through the acquired channel (bytes written, a datagram sent) and crosses the boundary. To recover from emissions a system can withhold them until the producing state is certain to persist (the output commit problem) or compensate (delete the created file, refund the charge) up to a coarser, application-supplied equivalence. Compensations compose LIFO like inverses, but the commutation results of §4 would have to be re-established for the coarser equivalence.

**Service multiplexing (§6.2).** A service is the interface behind a key; providers and consumers as in OSGi. Multiple implementations can be handled by exclusive binding (one bound at a time; switching unloads one and loads another and perturbs every consumer) or by a service broker (one fiber provides the key; backing providers and consumers both inject it; providers register with it through revertible effects; updating a backing provider triggers no consumer reload). The broker enables load balancing (policy or explicit target; providers added or removed to scale), rolling updates (load the new provider, shift traffic when it is `ACTIVE`, unload old providers when they carry no in-flight requests), and cross-process invocation (each process has its own context; a coordinating component treats the others as remote providers over RPC). Interfaces meant to cross processes must be asynchronous because calls have latency and can fail mid-flight.

**Access control and sandboxing (§6.3).** The proxy access check is capability-style: `inject` is a capability request known before the component runs, so an orchestrator can review it at load time; the context proxy is the mediator. Interception generalizes this to fine-grained policy: metadata carried by a context or declared by a component is consulted by the provider at invocation (the examples are permitted filesystem paths and read-only database access for a community component). Because interception changes how a dependency is used and not whether it is satisfied, it can be installed, changed or removed at runtime with no reload. Language-level mediation does not contain untrusted code, which can reach host objects directly. Sandboxing needs an execution boundary outside the language (software fault isolation, a separate runtime, a sandboxed process, a container); the untrusted component reaches host dependencies through a bridge that is an ordinary host-side fiber whose capabilities are attenuated by interception.

**Language independence and selection (§6.4).** Requirements on a host language. Temporal: closures (an inverse must capture the state it restores), and a way to introduce and retract code at runtime: a programmatic module registry in managed runtimes (CommonJS exposes `require.cache`; ES modules have no public eviction API), `dlopen`/`dlclose` or `LoadLibrary`/`FreeLibrary` for native code, instance reclamation for WebAssembly. Spatial: dependency declaration plus runtime injection, at two levels. Type level: the context type must record each key's coeffect and be extensible from the provider's module (Haskell typeclass instances, Rust trait impls, TypeScript module augmentation). Runtime level: access must be interposed transparently because the binding behind a key changes and differs per context (JavaScript `Proxy`, Python `__get__` descriptors), or else reflection at a cost in type safety. Metaprogramming (annotations, decorators, Rust procedural macros, Scala macros, Zig comptime) can emit a typed declaration and an accessor per dependency and remove the need for a general interception primitive.

**Mutual dependencies and granularity (§6.5).** A dependency cycle leaves the components permanently inactive; neither satisfaction predicate can become true. Unlike a schedule-dependent deadlock this is predictable from declarations, so a runtime can report it at load time. Apparent cycles are decomposed: a server and an access controller that use each other become `server-core`, `access-control-core`, `request-mediation` (depends on both cores) and `policy-management` (depends on both cores). The decomposition is always possible in principle but the number of integration components can grow quadratically. This costs developer effort, not correctness or runtime performance. Mitigations: package bundling, convention-based wiring, scaffold tooling.

**Dependency typing and versioning (§6.6).** Linking is by key identity only. Two failure modes across independently built components: interface drift (the provider changes the interface behind `k`; the dependency is satisfied but the value does not conform) and key collision (two unrelated providers use the same key). Three approaches: key namespacing (`K × P` with the interface-defining package; removes collisions but couples key identity to a package registry); peer dependencies through the host package manager, which is what Cordis does now (caught at install time; relies on semantic versioning discipline; one version per package per application); structural compatibility (replace `k ∈ dom(σ)` with a subsumption check; simple for records, complex for behavioral specifications, undecidable with bounded quantification). A unified model is an open problem.

**Co-design with languages and operating systems (§6.7).** A language built for the paradigm could make the context implicit while keeping multiple contexts (in-place operations modify the ambient context; derived realization needs a construct that introduces a separate one). Benefits: functions stop taking the context as an argument, and a component can no longer reach another component's context through a closure or a global, which today lets an effect leak out of its lifecycle or a read escape its specification. A compiler that knows effects could compile an effect iterator to one state machine holding the inverses in its frame instead of allocating a closure per step; a type system that knows specifications could report cycles at compile time and compare dependencies structurally (row types). An operating system built for the paradigm could bound a component to exactly the dependencies it declares (as a WebAssembly module receives its imports at instantiation), provide isolation and interception itself, provide memory and file descriptors as coeffects with one acquisition record kept by the OS, and make some emissions revertible through transactional storage or copy-on-write and immutable storage.

**Limits collected from the whole paper.** Witnesses are unchecked (paper:6177-6186). Guarantees hold up to `≃` and say nothing about state no key binds. Progress and confluence assume an acyclic precedence relation; confluence also assumes components total on their provision and excludes failed fibers. Confluence is about the final state, not emissions. A component's own in-memory state does not survive a reload unless it is placed in a longer-lived dependency; forward state migration is future work (paper:7424-7428). The case study is observational.

## Related work

**§7.1 Effect and coeffect systems.** Monadic effect systems (ZIO `ZIO[R,E,A]`, Effect-TS `Effect<A,E,R>`, fp-ts Reader stacks): tracking requires writing the program inside the effect type, and a requirement is discharged by an installed service whose past actions remain when it is withdrawn; Cordis tracks as an overlay on ordinary code, pairs each effect with an inverse and re-resolves requirements. Algebraic effects as capabilities (Effekt): shares the view of the context as a mediator of capabilities; differs in purpose (modular interpretation with many handler semantics versus tracking and reversion) and setting (static, second-class capabilities confined to lexical scope with boxing versus runtime discipline). Reversible effects as inverse arrows (Heunen, Kaarsgaard, Karvonen): closest formal account; there reversibility is global, two-sided and derived from categorical structure, while Cordis requires only a one-sided inverse per atomic effect, supplied at the point of application, with composite inverses by composition. Graded modal types (Granule; coeffects for Java-like languages; call-by-push-value): all static; the paper's contribution is orthogonal, lifting both notions to runtime.

**§7.2 Programming paradigms.** Explicit state threading (the State monad) gives equational reasoning at the cost of threading; imperative mutation is ergonomic but untraceable; the context paradigm routes effects and coeffects through a context the component holds and leaves everything else as ordinary host code, as an overlay realizable on either style. Context-oriented programming (layers, ContextL): also has runtime-mutable context and dynamic activation, but "context" there is the ambient situation, activation changes method dispatch in a dynamically scoped extent, and layers neither track nor revert side effects and are not driven by dependency satisfaction; Cordis can express only COP's global, value-driven selection among implementations, not dynamically scoped activation. Aspect-oriented programming: a coeffect is the analogue of an aspect, a shared mediation point; differences are declaration versus obliviousness (crosscutting reaches only declared coeffects, so an orchestrator can inspect it in configuration) and lifecycle integration (a crosscutting change is a component's effect, reverted on unload and propagated to dependents; dynamic AOP weaves at runtime but as a standalone operation).

**§7.3 Temporal composability, four families.**

1. Stateful forward migration. Quiescence (Kramer and Magee) and tranquility (Vandewoude et al.) as the timing discipline, which the rolling-update pattern follows by draining in-flight requests. Dynamic software updating for C (Hicks et al.; Stoyle et al.; Kitsune) with hand-written state transformers. Event-store schema upgrades. Erlang/OTP: state migration through `code_change/3` and fault recovery by restarting supervised processes, not by reverting their effects. JavaScript HMR in webpack and Vite: state handed forward through `module.hot` or `import.meta.hot`. These migrate in-memory state more gracefully than Cordis, which reverts and reapplies from a clean state; Cordis needs no migration functions and supports full removal.
2. Developer-authored recovery. Plugin unload callbacks (OSGi, Eclipse, IntelliJ, VSCode), the Command pattern with undo, sagas with compensating actions, finalizers attached by algebraic effect handlers, event sourcing with compensating events. The inverse is an unenforced duty separate from the operation. React `useEffect` is the closest structural pairing of effect and cleanup, but hooks may be called only at the top level of a component or hook, not in conditionals, loops or nested functions, and the effect body accepts neither an async function nor an iterator, so effects cannot be composed or interleaved with control flow. Cordis effects are ordinary operations that compose, may be asynchronous, and need a hand-written inverse only per atomic effect.
3. Statically scoped reversal. Software transactional memory (read/write log, commit or abort of a group of memory operations), descended from hardware transactional memory. Reversible computing (Landauer, Bennett, Janus). Reversible process calculi (RCCS; Phillips and Ulidowski), whose causal-consistency criterion is called the concurrent counterpart of Cordis's recovery order (LIFO within a component, provider after consumers). Linear types, RAII and Rust ownership tie release to a lexical region. All fix the scope of reversal in advance; Cordis fixes none and treats lexical resource management as complementary for local resources. Kim and Rinard verify inverses and commutativity conditions for set and map operations on abstract state, showing both ingredients §3.4 requires are mechanically checkable at typical key interfaces; their inverses do not compose.
4. Interposed reclamation. Nooks (object tracker on calls between the Linux kernel and extensions), shadow drivers, Akeso recovery domains. The runtime keeps the record, which makes this the closest systems precedent; but the platform fixes what can be recorded, and reclamation is bounded by a request or a restart, whereas a Cordis component introduces its own effects with inverses, reverts over its whole lifetime and propagates removal to dependents.

**§7.4 Spatial composability, three families.** Initialization-time wiring: dependency injection containers (Spring, Guice, Angular, Inversify) and UI context (Vue `provide`/`inject`, React Context); some have dynamic scopes, none re-resolves reactively or manages lifecycle when a provider is replaced. Availability-reactive component models: OSGi Declarative Services and iPOJO activate and deactivate components as services appear and disappear, and are called the direct precursor of `ctx.provide`/`ctx.get`; R-OSGi extends this over RPC. Their deactivation callbacks are hand-written and synchronous, with no protocol to await an asynchronous exchange with a departing dependency; Cordis reverts accumulated effects and its inertial `Unloading` state runs asynchronous teardown to completion. Value-level reactivity: FRP and signals (SolidJS, Vue, Angular Signals; the cited sources include FrTime and Scala.React) propagate per value within a turn and can guarantee glitch freedom; Cordis reacts per component with asynchronous lifecycle, has no turn, and guarantees only that no single transition straddles two resolutions (Theorem 71). The two are complementary; a coeffect can carry reactive values.

**Elsewhere in the paper.** Delimited continuations appear twice: the effect iterator is "a reified delimited continuation" exposed by `yield` (citing James and Sabry, paper:1252-1254), and Kiselyov and Shan's "Delimited Continuations in Operating Systems" is cited for reaching an earlier state on immutable storage (paper:7283). Module linking (Cardelli) is the static form of spatial composability (paper:127). Bracket patterns (asynchronous exceptions in Haskell) and RAII are the static form of temporal composability (paper:126). Fresh local names (Pitts and Stark) model fiber identity. Trace theory (Mazurkiewicz) underlies transposition. Adaptive functional programming (Acar et al.) is the analogue of confluence as consistency with from-scratch evaluation. CRDTs, CompCert's memory injections and the scalable commutativity rule support the commutativity recipe. Capability security (Dennis and Van Horn; Miller et al.; Capsicum) supports §6.3.

**Lisp, Scheme and Racket: what the paper says.** The paper does not mention `dynamic-wind`, Racket parameters, custodians, units, ML modules or functors, or any Lisp-family language by name. Two cited works are Lisp-family systems, a fact the paper does not state and this note adds: ContextL (reference 95) is a CLOS extension, and FrTime (reference 124, Cooper and Krishnamurthi) is implemented in PLT Scheme, the predecessor of Racket.

**Lisp, Scheme and Racket: placement in the paper's taxonomy (this note's analysis, not the paper's).**

- `dynamic-wind` belongs with "statically scoped reversal": pre and post thunks bracket a dynamic extent. A plugin's effects outlive the extent of its `apply` call, so `dynamic-wind` cannot be the tracking primitive. It is suitable inside the kernel for installing and removing an ambient "current fiber" around a callback.
- Parameters are the "implicit context" of §6.7 and behave like a derived realization (Definition 23): `parameterize` creates a new binding visible in an extent and undone by leaving it. A `current-context` parameter can supply the context to service procedures. Captured continuations and new threads carry parameterizations, which is the cross-component context access §6.7 warns about, so the explicit context value must remain the unit of ownership.
- Custodians belong with "interposed reclamation": the runtime records platform resources (threads, ports, listeners, places) and can shut them all down. They have no ordering, no user-defined inverses and no dependency awareness, and `custodian-shutdown-all` is immediate, which would violate Theorem 70 if used before dependents finished teardown. A fiber-owned custodian is a reasonable fallback applied after the accumulator has run at L-Unload, never in place of it.
- Units (`racket/unit`) belong with "initialization-time wiring" and module linking: imports and exports are checked at link time and never re-resolved. Signatures are a possible static description of what a key provides.
- Generators and delimited control (`racket/generator`, `call-with-continuation-prompt`, `racket/control`) are a direct realization of the effect iterator: each `yield` of a disposer is an iteration boundary.
- Contracts can check that a disposer is a procedure and that `inject` and `provide` declarations have the right form, but not the semantic witnesses, which stay author obligations as in the paper.
- Racket has no promise type that runs eagerly; `create_task` must spawn (a thread or an explicit task queue), as the paper's footnote says for lazy hosts.

## Laws an implementation should test

Each item is phrased as an executable property. "Observe" means compare through public operations of the context and its services (store key sets per realm, listener and registration counts, lifecycle states), because the theory guarantees equality only up to `≃`.

### Effect algebra (pure model or kernel unit tests)

1. Disposer order inside one effect: an effect that collects disposers `d1..dn` runs them `dn..d1` on dispose (Definitions 1, 3; Theorem 16).
2. Tracking does not change forward behavior: the observable result of an action is the same with and without `effect` around it (Theorem 4).
3. Composition: an effect that performs two sub-effects and one that nests two `effect` calls produce the same state and the same state after dispose (Theorems 5, 13).
4. Round trip: for any sequence of correct effects registered on a fiber, unloading the fiber restores the starting observation (Theorem 7).
5. Empty effect: a callback that returns nothing or a no-op disposer is accepted and disposes cleanly (Theorem 10).
6. Early dispose: disposing one effect by its returned disposer restores that effect's contribution only, and a later fiber unload still restores the start and does not run that disposer again (Theorem 15; single-shot rule of Algorithm 1).
7. Disposer idempotence: calling a disposer twice has the effect of calling it once.
8. Iterator boundary: stop an async iterator effect after `k` of `n` yields (by changing the fiber's target); exactly `k` inverses are held and all `k` run at unload; iterations after the stop do not run (Definition 18; Algorithm 1).
9. Plain effect equals one-step iterator: a callback returning a disposer and a generator yielding that one disposer behave the same (equation 19).
10. Parent composition: disposing a parent effect disposes effects registered inside it; unloading a fiber disposes effects of contexts derived from it (Definition 12; Definition 28).

### Coeffect table

11. Double provision of one key in one realm raises and leaves the first binding intact (Definition 19).
12. Provide then dispose leaves the key absent, and dependents are notified at both changes (Definition 20; Algorithm 2).
13. `get` of an absent key returns nothing and does not raise; proxy access to an undeclared key raises; proxy access to a declared but uncommitted key raises a different error (Algorithm 6).
14. Classification: a fiber's `apply` runs exactly when satisfaction goes from false to true, its unload runs exactly when it goes from true to false, and a change at an undeclared key or a repeated notification causes neither (Definition 22).
15. Isolation: contexts with different realms for a key hold independent bindings; `isolate` on a child does not change what the parent resolves; a key that was never isolated resolves in the shared realm; notification reaches only fibers that resolve the key in the same realm (Definitions 24, 25; Algorithm 3).
16. Interception: the provider sees the component's declared metadata merged with context-carried metadata, context-carried winning; adding, changing or removing interception triggers no lifecycle transition (Definition 27; §6.3).
17. Provider identity: replacing a provider by a different fiber that provides an equal value reloads dependents; a provider that overwrites its own binding in place does not (paper:6477-6483).

### Independence

18. Any-order revert: register `n` entries in a table-valued service from `n` effects; dispose them in every permutation (or random permutations); the table ends empty and each dispose removes exactly its own entry (Theorem 43; Definition 46). Run this against every registry-like service of the port (events, tools, commands).
19. Operations on different services commute: interleavings of registrations on two services give the same observation (Theorem 45).
20. Removing one component from a running system: with `A` and `B` unrelated and both active, unloading `A` leaves every observation of `B`'s contributions unchanged (Theorem 68).

### Lifecycle and ordering

21. Well-formedness after every step of a randomized schedule: every parent exists; no two live provisions share a key in one realm; every loading, active or unloading fiber has a committed view covering all of its `inject` keys; every provider named by a committed view is itself not inactive (Definition 63; Theorem 64).
22. Activation only when satisfied: `apply` never starts while a declared key lacks an active provider (Theorem 70).
23. Provider outlives consumer: record timestamps; no disposer of a provider runs before every consumer that committed to it has finished unloading (Theorem 70(2)).
24. Teardown can read: inside a consumer's disposer, triggered by the provider being disposed, `ctx[key]` still returns the provider's value (Theorem 70(3); Algorithm 6).
25. Out of service first: when a provider starts unloading, its dependents enter `UNLOADING` before any of the provider's disposers runs, and a new consumer does not activate against it (L-Leave; paper:6322-6327).
26. Resolution coherence: replace a provider while a consumer's async `apply` is between yields; the consumer never reports `ACTIVE` against the old provider, its partial effects are reverted, and it then loads against the new provider (Theorem 71).
27. Inertia: toggling a dependency on and off repeatedly during a slow load never runs two transitions of one fiber concurrently, and the final state matches the final target (§4.4; Algorithm 5).
28. Terminal recovery: after a fiber unloads, it provides no keys and holds no effects (Corollary 69).
29. Cascade: disposing a parent disposes children and grandchildren; children created during `apply` are gone after the parent unloads (Definition 52).
30. Retirement is permanent: a disposed fiber never becomes active again when its dependencies reappear; re-enabling creates a fiber with a new uid (Lemma 59(5); §4.4 Configuration).
31. Removal preconditions: a fiber leaves the registry only after it is inactive and holds nothing, and children leave before parents (O-Remove).
32. Failure containment: an `apply` that throws after registering effects leaves none of those effects in place, marks the fiber `FAILED`, does not affect parent or siblings, and is not retried by dependency notifications until an explicit update or reinsertion (§4.4 Failure).
33. Dependency cycle: two plugins that each inject what the other provides stay inactive, raise no error, and do not block `await` on unrelated fibers (§6.5).
34. Uid independence: running the same scenario with a different uid allocation gives the same observations (Lemma 61).
35. Disposed entries are invisible: a disposed child fiber still referenced by a list or by its entry does not affect resolution of any key (Lemma 62).

### Progress and confluence (property tests over random schedules)

36. Quiescence: for acyclic `inject`/`provide` graphs and finite effects, after any finite sequence of inserts and retires, awaiting all fibers terminates with every fiber stable (Theorem 73).
37. Support set: at quiescence the active fibers are exactly the least solution of "not disposed, parent active or root, every injected key provided by an active fiber", provided each plugin installs every key it declares (Lemma 77).
38. Schedule independence: the same final set of plugins and configs, applied in different insertion orders and with different interleavings of async steps, gives the same active set and the same observation (Theorem 80(2)).
39. History independence: add, remove, add again; replace a provider and undo the replacement; the observation equals loading the final configuration once from scratch (Theorem 80(1)).

### Loader and hot reload

40. Reconciliation equals fresh load: applying any sequence of entry edits and then quiescing gives the same observation as loading the final tree from empty (Theorem 80 applied in §5.2.1).
41. Per-field dispatch: changing `intercept` reloads nothing; changing `disabled` unloads or loads only that entry's fiber and its dependents; changing `id` or `url` rebuilds that entry; a group applies a keyed diff by child `id` (§5.2.1).
42. Realm reassignment: after changing an entry's `isolate`, a binding the entry provides moves with it, a binding it only consumes does not, and exactly the dependents whose visibility changed are notified (Algorithm 7).
43. HMR classification: for a given import graph, stashed set and externals set, accepted and declined sets equal the fixed point of Algorithm 8, with cycle members declined; stale entries are those whose import closure (not crossing declined modules) meets the accepted set (Algorithm 9).
44. HMR transaction: when one stale module fails to import, every stale entry ends up running the previous module version, and the error is reported (Algorithm 10).

## Quotable definitions

Quotes are verbatim, with line-break hyphenation removed, math italics written as plain letters, and typographic apostrophes written as ASCII.

- Abstract, revertible effects: "every context transformation carries an inverse that the runtime holds"
- Abstract, reactive coeffects: "every context change is classified against a component's coeffect specification to drive its activation and deactivation"
- Abstract, context paradigm: "mediate every effect and coeffect through it, yielding a discipline we call the context paradigm"
- §1.1, temporal composability: "upon removal of a component, the modifications the component made to the shared environment must be completely and safely reversed"
- §1.1, spatial composability: "components must be able to declare, discover, and resolve their dependencies on one another in a structured and verifiable manner"
- §3.1, effect type: "applied to the current context, it yields the modified context together with an explicit inverse"
- §3.1.1, left inverse: "Undoing is one-sided: what an inverse is held to is g ∘ f and never f ∘ g."
- §3.1.1, accumulator (Definition 2): "the composite of the inverses of the effects performed so far, and the function that recovers the context to its initial state"
- §3.1.2, witness (Definition 8): "the inverse is required to revert the effect only at the state where it was applied"
- §3.1.3, load and unload: "Loading a component is running one iterator and accumulating its inverses in φ; unloading it is applying φ."
- §3.2, reactive: "by classifying context changes and driving activation and deactivation from them, local spatial composability becomes a structural guarantee"
- §3.2.2, local spatial criterion: "a component activates only at a state satisfying its specification, so it never reads a binding that is absent"
- §3.2.3, derived realization (Definition 23): "Derived realization leaves the input intact and returns a fresh context deriving from it, with the identity as its inverse"
- §3.3.1, single entity: "Every interaction between a component and its environment passes through this single entity."
- §3.3.2, observational equivalence: "two states are related when no observer can distinguish them"
- §3.4.1, independence (Definition 42): "every transformation of one commutes with every transformation of the other"
- §3.4.2, commutative key: "A key whose value is a table of entries is commutative when each registration takes an entry of its own"
- §3.4.2, non-commutative key: "A key whose value is an ordered chain is not commutative"
- §4, component: "each a triple of a coeffect specification, a provision, and a witnessed effect function"
- §4.1, fiber: "One component may be instantiated many times over, and each instantiation is activated and deactivated over time"
- §4.2.1, orchestration: "the orchestrator requests that a fiber exist or stop existing, and never sets its lifecycle state directly"
- §4.2.2, target view (Definition 53): "The target view of n at γ maps each declared key to its provider"
- §4.2.2, quiescence (Definition 53): "A state is quiescent when every fiber has settled at its target view, no transition left in progress"
- §4.2.2, L-Unload: "it is the only rule in the calculus that applies an accumulator"
- §4.2.2, guard: "holds a provider's withdrawal back until every consumer that resolves a key to n has gone"
- §4.3.5, confluence: "The lifecycle relation is confluent, and the normal form it converges on is the statically assembled one."
- §4.4, failure: "Confluence excludes failed fibers"
- §5.1.1, single primitive: "Every context mutation in Cordis flows through a single primitive, ctx.effect"
- §5.1.1, unchecked witness: "that the inverse reverts the effect it accompanies is an obligation on the component author rather than a property the runtime verifies"
- §5.1.3, inertia: "once a transition begins, it completes before any new transition can start"
- §6.1, inside the boundary: "A location lies inside when the system is able to modify it exclusively and to restore the state before that modification"
- §6.5, cycles: "a dependency cycle simply leaves the involved components permanently inactive"
