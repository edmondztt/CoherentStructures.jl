using CoherentStructures, Test
using OrdinaryDiffEq, DiffEqOperators, DiffEqDevTools, SparseArrays, LinearAlgebra

dts = 0.5 .^(12:-1:7)
u0 = sin.(range(0, pi, length = 100))
tspan = (0.0, 1.0)


A = spdiagm(-1 => ones(99) , 0 => fill(-2, 100) , 1 => ones(99))
f = DiffEqArrayOperator(A)
sol_analytic = (u0,p,t) -> exp(t*Matrix(A)) * u0
prob = ODEProblem(ODEFunction(f; analytic=sol_analytic), u0, tspan)

sim1 = test_convergence(dts, prob, LinearImplicitEuler(linsolve=LinSolveFactorize(lu)))
@test sim1.𝒪est[:final] ≈ 1 atol = 0.2

sim2 = test_convergence(dts, prob, LinearMEBDF2(linsolve=LinSolveFactorize(lu)))
@test sim2.𝒪est[:final] ≈ 2 atol = 0.2


M = 0.5Diagonal(ones(100))
A = spdiagm(0 => ones(100))
update_func = (_A, u, p, t) -> _A.nzval .= t
f = DiffEqArrayOperator(A; update_func=update_func)

sol_analytic = (u0,p,t) -> exp(t^2/(2*0.5)) .* u0
prob = ODEProblem(ODEFunction(f; analytic=sol_analytic, mass_matrix=M), u0, tspan)

sim1 = test_convergence(dts, prob, LinearImplicitEuler(linsolve=LinSolveFactorize(lu)))
@test sim1.𝒪est[:final] ≈ 1 atol = 0.2

sim2 = test_convergence(dts, prob, LinearMEBDF2(linsolve=LinSolveFactorize(lu)))
@test sim2.𝒪est[:final] ≈ 2 atol = 0.2

# rot_double_gyre
N = 25
δ = 1e-8
ϵ = 1e-2
ctx, _ = regularTriangularGrid((N, N))
circleFun = x -> (sqrt((x[1] - 0.5)^2 + (x[2] - 0.5)^2) < 0.1) ? 1.0 : 0.0
sol = CoherentStructures.advect_serialized_quadpoints(ctx, (0.0, 1.1), rot_double_gyre!, nothing, δ)
M = assembleMassMatrix(ctx)
A = assembleStiffnessMatrix(ctx)

function update_coeffs!(A, u, p, t)
    vals = SparseArrays.nzvalview(A)
    vals .= CoherentStructures.stiffnessMatrixTimeT(ctx, sol, t, δ).nzval
    vals .*= ϵ
    A
end

f = DiffEqArrayOperator(A; update_func=update_coeffs!)
u0 = nodal_interpolation(ctx, circleFun)
tspan = (0.0, 1.0)

prob = ODEProblem(ODEFunction(f; mass_matrix=M), u0, tspan)

sol1 = solve(prob, LinearImplicitEuler(linsolve=LinSolveFactorize(lu)), dt=0.1)
sol2 = solve(prob, LinearMEBDF2(linsolve=LinSolveFactorize(lu)), dt=0.1)

@test sol1.retcode == :Success
@test sol2.retcode == :Success
@test sol1.u[end] ≈ sol2.u[end] atol=1e-1