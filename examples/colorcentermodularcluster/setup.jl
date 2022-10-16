# For convenient graph data structures
using Graphs

# For discrete event simulation
using ResumableFunctions
using SimJulia

# For sampling from probability distributions
using Distributions

# Useful for interactive work
# Enables automatic re-compilation of modified codes
using Revise

# The workhorse for the simulation
using QuantumSavory

##

# """Start timeouts on two nodes that were just entangled.
# After the timeout, assume they are bad, delete them,
# and start entangling them again.""" # TODO this should be a separate per-node process
@resumable function bk_mem(env::Environment, net, node, conf)
    # check we have not set a decay timer on this node and set one
    decay_queue = net[node, :decay_queue]
    nspin_queue = net[node, :nspin_queue]
    !isfree(decay_queue) && return
    @yield request(decay_queue)
    @yield timeout(env, conf.BK_mem_wait_time)
    # reset the nuclear spin by measuring it
    @yield request(nspin_queue) # TODO you need to request the electronic spin too
    reg = net[node]
    @yield timeout(env, conf.BK_measurement_duration)
    flip = project_traceout!(reg, 2, [States.Z₀, States.Z₁]; time=now(env)) # FIXXX
    if rand()>conf.BK_measurement_fidelity # TODO this should be prettier, presumably implemented declaratively inside of project_traceout!
        flip = flip%2+1
    end
    # correct for logical flips
    for neigh in neighbors(net, node)
        if flip==2 && net[(node, neigh), :link_register]
            apply!(net[neigh,2], Z; time=now(env)) # TODO have a pauli frame tracker
        end
        net[(node, neigh), :link_register] = false
    end
    release(nspin_queue)
    release(decay_queue)
    # start entangling procedure again
    for neigh in neighbors(net, node)
        @process barrettkok(env, net, node, neigh, conf)
    end
end

#"""Set the state of the electronic spins to entangled."""
function bk_el_init(env::Environment, net, nodea, nodeb, conf)
    rega = net[nodea]
    regb = net[nodeb]
    initialize!([rega[1],regb[1]], conf.BK_electron_entanglement_init_state; time=now(env)) # TODO explicit physics of the initial state
    apply!(rega[1], H; time=now(env)) # TODO check whether this gate and the H gate in preparing the nuclear spin are necessary
    #apply!([rega], [1], Gates.Depolarize(conf.BK_electron_singleq_fidelity))
    # TODO call this MonteCarloDepolarize
    #skip dep gate rand()>conf.BK_electron_singleq_fidelity && apply!(rega[1], Gates.Depolarize(0.0))
    # TODO enable this timeout
    #@yield timeout(env, conf.BK_electron_gate_duration)
    # TODO relate the above depolarization to the duration of the H gate
end

#"""Swap between the electronic and nuclear spins of a node"""
function bk_swap(env::Environment, net, node, conf)
    reg = net[node]
    # check whether the nuclear register contains anything
    if !isassigned(reg, 2) # TODO the nuclear initialization should be separate and explicit, including wait time
        initialize!(reg[2]; time=now(env)) # TODO the following depolarization should be declarative when setting up the system
        #apply!([reg], [2], Gates.Depolarize(conf.BK_nuclear_init_fidelity))
        # TODO call this MonteCarloDepolarize
        #skip dep gate rand()>conf.BK_nuclear_init_fidelity && apply!(reg[2], Gates.Depolarize(0))
        apply!(reg[2], H) # TODO the following depolarization should be declarative when setting up the system
        #apply!([reg], [2], Gates.Depolarize(conf.BK_nuclear_singleq_fidelity))
        # TODO call this MonteCarloDepolarize
        #skip dep gate rand()>conf.BK_nuclear_singleq_fidelity && apply!(reg[2], Gates.Depolarize(0))
        # TODO relate the above depolarization to the duration of the H gate
        # TODO move the wait time for H in here
        #@yield timeout(env, BK_nuclear_gate_duration)
    end
    # perform the CPHASE gate
    apply!([reg[1],reg[2]], CPHASE; time=now(env)) # TODO the following depolarization should be declarative when setting up the system
    #apply!([reg,reg], [1,2], Gates.Depolarize(conf.BK_swap_gate_fidelity))
    # TODO call this MonteCarloDepolarize
    #skip dep gate rand()>conf.BK_swap_gate_fidelity && apply!([reg[1],reg[2]], Gates.Depolarize(0))
    # TODO relate the above depolarization the the duration of the SWAP gate
    # TODO move the wait time for SWAP in here
    #@yield timeout(env, BK_swap_gate_duration)
    # perform the projective measurement on the electron spin
    off = project_traceout!(reg[1], σˣ) # TODO use a projector object instead of a list
    if rand()>conf.BK_measurement_fidelity # TODO this should be prettier, presumably implemented declaratively inside of project_traceout!
        off = off%2+1
    end
    # TODO CONSTS wait time for measurement
    # TODO relate wait time for measurements to measurement fidelity
    return off
end

@resumable function barrettkok(env::Environment, net, nodea, nodeb, conf)
    # check whether this link is already being attempted
    link_resource = net[(nodea, nodeb), :link_queue]
    !isfree(link_resource) && return
    # if not, reserve both electronic spins, by using a nongreedy multilock
    spin_resources = [net[nodea, :espin_queue], net[nodeb, :espin_queue]]
    @yield request(link_resource)
    @yield @process nongreedymultilock(env, spin_resources)
    #@simlog env "got lock on $(nodea) $(nodeb)"
    # wait for a successful entangling attempt (separate attempts not modeled explicitly)
    rega = net[nodea]
    regb = net[nodeb]
    attempts = 1+rand(conf.BK_success_distribution)
    duration = attempts*conf.BK_electron_entanglement_gentime
    @yield timeout(env, duration)
    bk_el_init(env, net, nodea, nodeb, conf)
    # reserve the nuclear spins, by using a nongreedy multilock
    nspin_resources = [net[nodea, :nspin_queue], net[nodeb, :nspin_queue]]
    @yield @process nongreedymultilock(env, nspin_resources)
    # wait for the two parallel swaps from the electronic to nuclear spins
    @yield timeout(env, conf.BK_swap_duration)
    r1 = bk_swap(env, net, nodea, conf)
    r2 = bk_swap(env, net, nodeb, conf)
    # if necessary, correct the computational basis - currently done by affecting the state # TODO use a pauli frame
    r1==2 && apply!(regb[2], Z)
    r2==2 && apply!(rega[2], Z)
    # register that we believe an entanglement was established
    net[(nodea, nodeb), :link_register] = true
    # release locks
    release.(nspin_resources)
    release.(spin_resources)
    release(link_resource)
    #@simlog env "success on $(nodea) $(nodeb) after $(attempts) attempt(s) $(duration)"
    if conf.BK_mem_resets
        @process bk_mem(env, graph, nodea, conf)
        @process bk_mem(env, graph, nodeb, conf)
    end
end

##

function prep_sim(root_conf)
    graph = grid([2,3])
    traits = [Qubit(),Qubit()]

    bg = [T2Dephasing(root_conf.T2E), T2Dephasing(root_conf.T2N)]

    net = RegisterNet(graph, [Register(traits,bg) for i in vertices(graph)])

    BK_total_efficiency = root_conf.losses*root_conf.ξ_optical_branching * root_conf.F_purcell / (root_conf.F_purcell-1+(root_conf.ξ_debye_waller*root_conf.ξ_quantum_efficiency)^-1)

    BK_success_prob = 0.5 * BK_total_efficiency^2
    BK_success_distribution = Geometric(BK_success_prob)

    BK_swap_duration = 10/root_conf.hyperfine_coupling # TODO CONSTS could be better than 10x TODO have a more precise factor than 10x

    BK_mem_wait_time = root_conf.BK_mem_wait_factor*mean(BK_success_distribution)*root_conf.BK_electron_entanglement_gentime

    observables = [reduce(⊗, [σˣ,fill(σᶻ,n)...]) for n in 1:5]
    BK_electron_entanglement_init_state = (Z₁⊗Z₁ + Z₂⊗Z₂) / √2
    BK_electron_entanglement_init_state = SProjector(BK_electron_entanglement_init_state)
    # CONSTS should include imperfections from measurements and from initialization/gates
    # electron measurement infidelity, dark counts, initialization infidelity, rotation gate infidelity
    dep(p,o) = p*o+(1-p)*MixedState(o)
    BK_electron_entanglement_init_state = dep(root_conf.BK_electron_entanglement_fidelity,BK_electron_entanglement_init_state)

    conf = (;
        root_conf...,
        BK_total_efficiency,
        BK_success_prob,
        BK_success_distribution,
        BK_swap_duration,
        BK_mem_wait_time,
        BK_electron_entanglement_init_state,
    )

    # set up SimJulia discrete events simulation
    sim = Simulation()

    for r in vertices(net)
        net[r, :espin_queue] = Resource(sim,1)
        net[r, :nspin_queue] = Resource(sim,1)
        net[r, :decay_queue] = Resource(sim,1)
    end
    for e in edges(net)
        net[e, :link_queue] = Resource(sim,1)
        net[e, :link_register] = false
    end

    for (;src,dst) in edges(net)
        @process barrettkok(sim, net, src, dst, conf)
    end

    net, sim, observables, conf
end

# time is measured in ms
# frequency is measured in kHz

root_conf = (;
    BK_mem_resets = false, # whether to reset memories after waiting too long

    T1E = 1.,    # 0.1ms if not well cooled, 10ms if cooled, neglected | Transform-Limited Photons From a Coherent Tin-Vacancy Spin in Diamond (Fig. 4c) | 10.1103/PhysRevLett.124.023602
    T2E = 0.01,  # 1μs without dyn decoup, 28μs with | Quantum control of the tin-vacancy spin qubit in diamond (Sec IV and V) | 10.1103/PhysRevX.11.041041
    T1N = 100e3, # generally very large, neglected, example in NV⁻ | A Ten-Qubit Solid-State Spin Register with Quantum Memory up to One Minute | 10.1103/PhysRevX.9.031045
    T2N = 100.,  # 0.1s before dyn decoup, 60s with, example in NV⁻ | A Ten-Qubit Solid-State Spin Register with Quantum Memory up to One Minute | 10.1103/PhysRevX.9.031045

    ξ_debye_waller = 0.57, # For SnV | Quantum Photonic Interface for Tin-Vacancy Centers in Diamond | 10.1103/PhysRevX.11.0310210
    ξ_quantum_efficiency = 0.8, # For SnV | Quantum Photonic Interface for Tin-Vacancy Centers in Diamond | 10.1103/PhysRevX.11.031021
    ξ_optical_branching = 0.8, # For SnV | Quantum Photonic Interface for Tin-Vacancy Centers in Diamond | 10.1103/PhysRevX.11.031021
    F_purcell = 10., # 1 without enchancement, 10 easy, 25 achieved | Quantum Photonic Interface for Tin-Vacancy Centers in Diamond | 10.1103/PhysRevX.11.031021

    losses = 0.1, # CONSTS should be explicit

    hyperfine_coupling = 42.6e3, # imposes the duration of the CPHASE gate, 42.6 MHz | Quantum control of the tin-vacancy spin qubit in diamond (end of Sec I) | 10.1103/PhysRevX.11.041041
    BK_electron_gate_duration = 0.000, # CONSTS TODO | depends on the electronic gyromag and applied field
    BK_nuclear_gate_duration = 0.000, # CONSTS TODO | depends on the nuclear gyromag and applied field, not really used, as these gates are tracked in the pauli frame

    # TODO this should be split in pieces, the dynamics should be simulated exactly
    BK_electron_entanglement_gentime = 0.015, # units of ms # CONSTS why?
    BK_electron_entanglement_fidelity = 1.0,

    BK_measurement_duration = 0.004, # CONSTS TODO
    BK_measurement_fidelity = 1., # CONSTS TODO
    BK_electron_init_fidelity = 1., # CONSTS TODO
    BK_nuclear_init_fidelity = 1., # CONSTS TODO
    BK_electron_singleq_fidelity = 1., # CONSTS TODO
    BK_nuclear_singleq_fidelity = 1., # CONSTS TODO
    BK_swap_gate_fidelity = 1., # CONSTS TODO
    BK_mem_wait_factor = 10,
)
