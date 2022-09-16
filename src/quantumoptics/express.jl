const _b2 = SpinBasis(1//2)
const _l = spinup(_b2)
const _h = spindown(_b2) # TODO is this a good decision... look at how clumsy the kraus ops are
const _s₊ = (_l+_h)/√2
const _s₋ = (_l-_h)/√2
const _i₊ = (_l+im*_h)/√2
const _i₋ = (_l-im*_h)/√2
const _lh = sigmap(_b2)
const _ll = projector(_l)
const _hh = projector(_h)
const _id = identityoperator(_b2)
const _z = sigmaz(_b2)
const _x = sigmax(_b2)
const _y = sigmay(_b2)
const _Id = identityoperator(_b2)
const _hadamard = (sigmaz(_b2)+sigmax(_b2))/√2
const _cnot = _ll⊗_Id + _hh⊗_x
const _cphase = _ll⊗_Id + _hh⊗_z
const _phase = _ll + im*_hh
const _iphase = _ll - im*_hh

express_nolookup(::HGate, ::QuantumOpticsRepresentation) = _hadamard
express_nolookup(::XGate, ::QuantumOpticsRepresentation) = _x
express_nolookup(::YGate, ::QuantumOpticsRepresentation) = _y
express_nolookup(::ZGate, ::QuantumOpticsRepresentation) = _z
express_nolookup(::CPHASEGate, ::QuantumOpticsRepresentation) = _cphase
express_nolookup(::CNOTGate, ::QuantumOpticsRepresentation) = _cnot

express_nolookup(s::XBasisState, ::QuantumOpticsRepresentation) = (_s₊,_s₋)[s.idx]
express_nolookup(s::YBasisState, ::QuantumOpticsRepresentation) = (_i₊,_i₋)[s.idx]
express_nolookup(s::ZBasisState, ::QuantumOpticsRepresentation) = (_l,_h)[s.idx]

express_nolookup(x::MixedState, ::QuantumOpticsRepresentation) = identityoperator(basis(x))/length(basis(x)) # TODO there is probably a more efficient way to represent it

function express_nolookup(s::Symbolic{T}, repr::QuantumOpticsRepresentation) where {T<:Union{Ket,Bra,Operator}}
    if istree(s)
        operation(s)(express.(arguments(s), (repr,))...)
    else
        error("Encountered an object $(s) of type $(typeof(s)) that can not be converted to $(repr) representation") # TODO make a nice error type
    end
end

apply!(state::Ket,      indices, operation::Symbolic{Operator}) = apply!(state, indices, express(operation, QOR))
apply!(state::Operator, indices, operation::Symbolic{Operator}) = apply!(state, indices, express(operation, QOR))

_overlap(l::Symbolic{Ket}, r::Ket) = _overlap(express(l, QOR), r)
_overlap(l::Symbolic{Ket}, r::Operator) = _overlap(express(l, QOR), r)

_project_and_drop(state::Ket, project_on::Symbolic{Ket}, basis_index) = _project_and_drop(state, express(project_on, QOR), basis_index)
_project_and_drop(state::Operator, project_on::Symbolic{Ket}, basis_index) = _project_and_drop(state, express(project_on, QOR), basis_index)

function project_traceout!(state::Union{Ket,Operator},stateindex,basis::Symbolic{Operator})
    project_traceout!(state::Operator,stateindex,eigvecs(basis))
end