using Distributed
nprocs() == 1 && addprocs()

@everywhere using CoherentStructures, OrdinaryDiffEq, StaticArrays

using JLD2
JLD2.@load("Ocean_geostrophic_velocity.jld2")
const VI = interpolateVF(Lon, Lat, Time, UT, VT)

import AxisArrays
const AA = AxisArrays
q = 91
const t_initial = minimum(Time)
const t_final = t_initial + 90
const tspan = range(t_initial, stop=t_final, length=q)
xmin, xmax, ymin, ymax = -4.0, 7.5, -37.0, -28.0
nx = 300
ny = floor(Int, (ymax - ymin) / (xmax - xmin) * nx)
xspan = range(xmin, stop=xmax, length=nx)
yspan = range(ymin, stop=ymax, length=ny)
P = AA.AxisArray(SVector{2}.(xspan, yspan'), xspan, yspan)
const δ = 1.e-5
mCG_tensor = u -> av_weighted_CG_tensor(interp_rhs, u, tspan, δ;
    p=VI, tolerance=1e-6, solver=Tsit5())

C̅ = pmap(mCG_tensor, P; batch_size=ny)
p = LCSParameters(2.5)
vortices, singularities = ellipticLCS(C̅, p)

using Plots
λ₁, λ₂, ξ₁, ξ₂, traceT, detT = tensor_invariants(C̅)
fig = Plots.heatmap(xspan, yspan, permutedims(log10.(traceT));
            aspect_ratio=1, color=:viridis, leg=true,
            title="DBS field and transport barriers",
            xlims=(xmin, xmax), ylims=(ymin, ymax))
scatter!(getcoords(singularities), color=:red, label="singularities")
scatter!([vortex.center for vortex in vortices], color=:yellow, label="vortex cores")
for vortex in vortices, barrier in vortex.barriers
    plot!(barrier.curve, w=2, label="T = $(round(barrier.p, digits=2))")
end
Plots.plot(fig)

using Interpolations, Tensors

const V = scale(interpolate(SVector{2}.(UT[:,:,1], VT[:,:,1]), BSpline(Quadratic(Free(OnGrid())))), Lon, Lat)

function rate_of_strain_tensor(xin)
    x, y = xin
    grad = Interpolations.gradient(V, x, y)
    df =  Tensor{2,2}((grad[1][1], grad[1][2], grad[2][1], grad[2][2]))
    return symmetric(df)
end

xmin, xmax, ymin, ymax = -12.0, 7.0, -38.1, -22.0
nx = 950
ny = floor(Int, (ymax - ymin) / (xmax - xmin) * nx)
xspan = range(xmin, stop=xmax, length=nx)
yspan = range(ymin, stop=ymax, length=ny)
P = AA.AxisArray(SVector{2}.(xspan, yspan'), xspan, yspan)

S = map(rate_of_strain_tensor, P)
p = LCSParameters(boxradius=2.5, pmin=-1, pmax=1)
vortices, singularities = ellipticLCS(S, p, outermost=true)

λ₁, λ₂, ξ₁, ξ₂, traceT, detT = tensor_invariants(S)
fig = Plots.heatmap(xspan, yspan, permutedims((λ₁));
            aspect_ratio=1, color=:viridis, leg=true,
            title="Minor rate-of-strain field and OECSs",
            xlims=(xmin, xmax), ylims=(ymin, ymax)
            )
scatter!([s.coords for s in singularities if s.index == 1//2 ], color=:yellow, label="wedge")
scatter!([s.coords for s in singularities if s.index == -1//2 ], color=:purple, label="trisector")
scatter!([s.coords for s in singularities if s.index == 1 ], color=:white, label="elliptic")
for vortex in vortices, barrier in vortex.barriers
    plot!(barrier.curve, w=2, color=:red, label="")
end
Plots.plot(fig)

using CoherentStructures
import JLD2, OrdinaryDiffEq, Plots

JLD2.@load("Ocean_geostrophic_velocity.jld2")

VI = interpolateVF(Lon, Lat, Time, UT, VT)

t_initial = minimum(Time)
t_final = t_initial + 90
times = [t_initial, t_final]
flow_map = u0 -> flow(interp_rhs, u0, times;
    p=VI, tolerance=1e-5, solver=OrdinaryDiffEq.BS5())[end]

LL = [-4.0, -34.0]
UR = [6.0, -28.0]
ctx, _  = regularTriangularGrid((150, 90), LL, UR)
bdata = getHomDBCS(ctx, "all");

M = assembleMassMatrix(ctx, bdata=bdata)
S0 = assembleStiffnessMatrix(ctx)
S1 = adaptiveTOCollocationStiffnessMatrix(ctx, flow_map)

S = applyBCS(ctx, 0.5(S0 + S1), bdata);

using Arpack

λ, v = eigs(S, M, which=:SM, nev=6);

using Clustering

ctx2, _ = regularTriangularGrid((200, 120), LL, UR)
v_upsampled = sample_to(v, ctx, ctx2, bdata=bdata)

function iterated_kmeans(numiterations, args...)
    best = kmeans(args...)
    for i in 1:(numiterations - 1)
        cur = kmeans(args...)
        if cur.totalcost < best.totalcost
            best = cur
        end
    end
    return best
end

n_partition = 4
res = iterated_kmeans(20, permutedims(v_upsampled[:,1:(n_partition-1)]), n_partition)
u = kmeansresult2LCS(res)
u_combined = sum([u[:,i] * i for i in 1:n_partition])
fig = plot_u(ctx2, u_combined, 200, 200;
    color=:viridis, colorbar=:none, title="$n_partition-partition of Ocean Flow")


Plots.plot(fig)

# This file was generated using Literate.jl, https://github.com/fredrikekre/Literate.jl
