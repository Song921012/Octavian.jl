
struct LoopMulFunc{P,TC,TA,TB,Α,Β,Md,Kd,Nd} <: Function end
function (::LoopMulFunc{P,TC,TA,TB,Α,Β,Md,Kd,Nd})(
  p::Ptr{UInt}
) where {P,TC,TA,TB,Α,Β,Md,Kd,Nd}
  offset, C = load(p, TC, 2 * sizeof(UInt))
  offset, A = load(p, TA, offset)
  offset, B = load(p, TB, offset)
  offset, α = load(p, Α, offset)
  offset, β = load(p, Β, offset)
  offset, M = load(p, Md, offset)
  offset, K = load(p, Kd, offset)
  offset, N = load(p, Nd, offset)
  _call_loopmul!(C, A, B, α, β, M, K, N, Val{P}())
  _atomic_store!(p, SPIN)
  nothing
end
@inline _call_loopmul!(C, A, B, α, β, M, K, N, ::Val{false}) =
  loopmul!(C, A, B, α, β, M, K, N)
@inline function _call_loopmul!(
  C::StridedPointer{T},
  A,
  B,
  α,
  β,
  M,
  K,
  N,
  ::Val{true}
) where {T}
  if M * K < ceil(Int, Float64(first_cache_size(Val(T)) * R₂Default()))
    packaloopmul!(C, A, B, α, β, M, K, N)
    return
  else
    matmul_st_only_pack_A!(
      C,
      A,
      B,
      α,
      β,
      M,
      K,
      N,
      W₁Default(),
      W₂Default(),
      R₁Default(),
      R₂Default()
    )
    return
  end
end
call_loopmul!(C, A, B, α, β, M, K, N, ::Val{P}) where {P} =
  _call_loopmul!(C, A, B, α, β, M, K, N, Val{P}())

struct SyncMulFunc{TC,TA,TB,Α,Β,Md,Kd,Nd,BCP,ID,TT,W₁,W₂,R₁,R₂} <: Function end
function (::SyncMulFunc{TC,TA,TB,Α,Β,Md,Kd,Nd,BCP,ID,TT,W₁,W₂,R₁,R₂})(
  p::Ptr{UInt}
) where {TC,TA,TB,Α,Β,Md,Kd,Nd,BCP,ID,TT,W₁,W₂,R₁,R₂}
  offset, C = load(p, TC, 2 * sizeof(UInt))
  offset, A = load(p, TA, offset)
  offset, B = load(p, TB, offset)
  offset, α = load(p, Α, offset)
  offset, β = load(p, Β, offset)
  offset, M = load(p, Md, offset)
  offset, K = load(p, Kd, offset)
  offset, N = load(p, Nd, offset)
  offset, atomicp = load(p, Ptr{UInt32}, offset)
  offset, bcachep = load(p, BCP, offset)
  offset, id = load(p, ID, offset)
  offset, total_ids = load(p, TT, offset)
  sync_mul!(
    C,
    A,
    B,
    α,
    β,
    M,
    K,
    N,
    atomicp,
    bcachep,
    id,
    total_ids,
    StaticFloat64{W₁}(),
    StaticFloat64{W₂}(),
    StaticFloat64{R₁}(),
    StaticFloat64{R₂}()
  )
  _atomic_store!(p, SPIN)
  nothing
end

@generated function cfuncpointer(::T) where {T}
  precompile(T(), (Ptr{UInt},))
  quote
    $(Expr(:meta, :inline))
    @cfunction($(T()), Cvoid, (Ptr{UInt},))
  end
end

@inline function setup_matmul!(
  p::Ptr{UInt},
  C::TC,
  A::TA,
  B::TB,
  α::Α,
  β::Β,
  M::Md,
  K::Kd,
  N::Nd,
  ::Val{P}
) where {P,TC,TA,TB,Α,Β,Md,Kd,Nd}
  offset = store!(
    p,
    cfuncpointer(LoopMulFunc{P,TC,TA,TB,Α,Β,Md,Kd,Nd}()),
    sizeof(UInt)
  )
  offset = store!(p, C, offset)
  offset = store!(p, A, offset)
  offset = store!(p, B, offset)
  offset = store!(p, α, offset)
  offset = store!(p, β, offset)
  offset = store!(p, M, offset)
  offset = store!(p, K, offset)
  offset = store!(p, N, offset)
  nothing
end

@inline function launch_thread_mul!(
  C,
  A,
  B,
  α,
  β,
  M,
  K,
  N,
  tid::UInt32,
  ::Val{P}
) where {P}
  launch(setup_matmul!, tid, C, A, B, α, β, M, K, N, Val{P}())
end

struct SyncMulLauncher{W₁,W₂,R₁,R₂} end
@inline function (::SyncMulLauncher{W₁,W₂,R₁,R₂})(
  p::Ptr{UInt},
  C::TC,
  A::TA,
  B::TB,
  α::Α,
  β::Β,
  M::Md,
  K::Kd,
  N::Nd,
  ap::Ptr{UInt32},
  bcp::BCP,
  id::ID,
  tt::TT
) where {TC,TA,TB,Α,Β,Md,Kd,Nd,BCP,ID,TT,W₁,W₂,R₁,R₂}
  fptr =
    cfuncpointer(SyncMulFunc{TC,TA,TB,Α,Β,Md,Kd,Nd,BCP,ID,TT,W₁,W₂,R₁,R₂}())
  offset = store!(p, fptr, sizeof(UInt))
  offset = store!(p, C, offset)
  offset = store!(p, A, offset)
  offset = store!(p, B, offset)
  offset = store!(p, α, offset)
  offset = store!(p, β, offset)
  offset = store!(p, M, offset)
  offset = store!(p, K, offset)
  offset = store!(p, N, offset)
  offset = store!(p, ap, offset)
  offset = store!(p, bcp, offset)
  offset = store!(p, id, offset)
  offset = store!(p, tt, offset)
  nothing
end
@inline function launch_thread_mul!(
  C,
  A,
  B,
  α,
  β,
  M,
  K,
  N,
  ap,
  bcp,
  tid,
  id,
  tt,
  ::StaticFloat64{W₁},
  ::StaticFloat64{W₂},
  ::StaticFloat64{R₁},
  ::StaticFloat64{R₂}
) where {W₁,W₂,R₁,R₂}
  launch(
    SyncMulLauncher{W₁,W₂,R₁,R₂}(),
    tid,
    C,
    A,
    B,
    α,
    β,
    M,
    K,
    N,
    ap,
    bcp,
    id,
    tt
  )
end
