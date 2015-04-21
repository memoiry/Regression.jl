# Numerical solver

## Solvers

abstract RiskMinSolver

_prep_searchdir(::RiskMinSolver, g::StridedArray) = similar(g)

# gradient descent

type GDSolver <: RiskMinSolver
end

init_states(::GDSolver, θ) = nothing

descent_dir!(::GDSolver, st::Nothing, θ::StridedArray, g::StridedArray, p::StridedArray) =
    (is(p, g) || copy!(p, g); p)

_prep_searchdir(::GDSolver, g::StridedArray) = g


## Options

type RiskMinOptions
    maxiter::Int        # maximum number of iterations
    ftol::Float64       # function value change tolerance
    xtol::Float64       # solution change tolerance
    grtol::Float64      # gradient norm tolerance
    armijo::Float64     # Armijo coefficient for line search
    beta::Float64       # backtracking ratio
    verbosity::Symbol   # verbosity (:none | :final | :iter)
end

function RiskMinOptions(;maxiter::Integer=200,
                         ftol::Real=1.0e-6,
                         xtol::Real=1.0e-8,
                         grtol::Real=1.0e-8,
                         armijo::Real=0.5,
                         beta::Real=0.5,
                         verbosity::Symbol=:none)

     maxiter > 1 || error("maxiter must be an integer greater than 1.")
     ftol > 0 || error("ftol must be a positive real value.")
     xtol > 0 || error("xtol must be a positive real value.")
     grtol > 0 || error("grtol must be a positive real value.")
     0 < armijo < 1 || error("armijo must be a real value in (0, 1).")
     0 < beta < 1 || error("beta must be a real value in (0, 1).")
     (verbosity == :none || verbosity == :final || verbosity == :iter) ||
         error("verbosity must be either :none, :final, or :iter.")

     RiskMinOptions(convert(Int, maxiter),
                    convert(Float64, ftol),
                    convert(Float64, xtol),
                    convert(Float64, grtol),
                    convert(Float64, armijo),
                    convert(Float64, beta),
                    verbosity)
end


## Solution

immutable RiskMinSolution{Sol<:StridedArray}
    sol::Sol
    fval::Float64
    niters::Int
    converged::Bool
end

function Base.show(io::IO, r::RiskMinSolution)
    println(io, "RiskMinSolution:")
    println(io, "- sol:       $(size(r.sol)) $(typeof(r.sol))")
    println(io, "- fval:      $(r.fval)")
    println(io, "- niters:    $(r.niters)")
    println(io, "- converged: $(r.converged)")
end


## Solve

function solve!{T}(rmodel::SupervisedRiskModel,    # the risk model
                   reg::Regularizer,               # the regularizer
                   θ::Array{T},                    # the solution (which would be updated inplace)
                   X::StridedArray{T},             # array of inputs
                   y::StridedArray,                # array of outputs
                   solver::RiskMinSolver,          # solver
                   options::RiskMinOptions,        # options to control the procedure
                   callback::Nullable{Function})   # callback function

    ## extract arguments and options

    maxiter = options.maxiter
    ftol = convert(T, options.ftol)
    xtol = convert(T, options.xtol)
    grtol = convert(T, options.grtol)
    armijo = convert(T, options.armijo)
    β = convert(T, options.beta)
    vbose = verbosity_level(options.verbosity)::Int

    ## prepare storage

    θ2 = similar(θ)    # tempoarily new parameter (linear search)
    g = similar(θ)     # gradient
    p = _prep_searchdir(solver, g)
    st = init_states(solver, θ)   # solver state

    ## main loop
    t = 0
    converged = false
    v, _ = value_and_grad!(rmodel, reg, g, θ, X, y)

    if vbose >= VERBOSE_ITER
        print_iter_head()
        print_iter(t, v)
    end

    while !converged && t < maxiter
        t += 1
        v_pre = v

        # compute descent direction
        descent_dir!(solver, st, θ, g, p)

        # backtracking
        dv = dot(vec(p), vec(g))
        dv > zero(T) || error("The descent direction is invalid.")
        α = one(T)
        _xmcy!(θ2, θ, α, p)   # θ2 <- θ - α p
        v2 = value(rmodel, θ2, X, y) + value(reg, θ2)
        while v2 > v - armijo * α * dv
            α > eps(T) || error("Failed to find a proper step size.")
            α *= β
            _xmcy!(θ2, θ, α, p)   # θ2 <- θ - α p
            v2 = value(rmodel, θ2, X, y) + value(reg, θ2)
        end

        θ, θ2 = θ2, θ  # swap current solution and new solution

        # compute new gradient
        v, _ = value_and_grad!(rmodel, reg, g, θ, X, y)

        # test convergence
        converged = abs(v - v_pre) < ftol ||
                    vecnorm(g) < grtol ||
                    _l2diff(θ, θ2) < xtol

        # print iteration
        if vbose >= VERBOSE_ITER
            print_iter(t, v, v_pre, g, α)
        end

        # invoke callback (when requested)
        if !isnull(callback)
            cf = get(callback)
            cf(t, θ, v, g)
        end
    end

    if vbose >= VERBOSE_FINAL
        print_final(t, v, converged)
    end

    return RiskMinSolution(θ, v, t, converged)
end


function solve{T}(rmodel::SupervisedRiskModel,
                  reg::Regularizer,
                  θ::StridedArray{T},
                  X::StridedArray{T},
                  y::StridedArray;
                  solver::RiskMinSolver=GDSolver(),
                  options::RiskMinOptions=RiskMinOptions(),
                  callback::Union(Nothing,Function)=nothing)

    cb = callback == nothing ? Nullable{Function}() :
                               Nullable(callback)
    solve!(rmodel, reg, copy(θ), X, y, solver, options, cb)
end
