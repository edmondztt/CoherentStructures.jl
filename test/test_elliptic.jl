using Test, StaticArrays, OrdinaryDiffEq, LinearAlgebra, CoherentStructures, AxisArrays
const CS = CoherentStructures

@testset "compute critical points" begin
    for x in (range(-1, stop=1, length=50), range(-1, stop=1, length=50)),
        y in (range(-1, stop=1, length=50), range(-1, stop=1, length=50))
        for v in (AxisArray(SVector{2}.(x, y'), x, y),
                AxisArray(SVector{2}.(-x, -y'), x, y),
                AxisArray(SVector{2}.(-y', x), x, y))
            S = @inferred compute_singularities(v)
            @test length(S) == 1
            @test iszero(S[1].coords)
            @test S[1].index == 1
            S = @inferred critical_point_detection(v, 0.1; merge_heuristics=[])
            @test length(S) == 1
            @test iszero(S[1].coords)
            @test S[1].index == 1
        end
        v = AxisArray(SVector{2}.(x, -y'), x, y)
        S = @inferred compute_singularities(v)
        @test length(S) == 1
        @test iszero(S[1].coords)
        @test S[1].index == -1
        S = @inferred critical_point_detection(v, 0.1; merge_heuristics=[])
        @test length(S) == 1
        @test iszero(S[1].coords)
        @test S[1].index == -1
    end
end

q = 3
tspan = range(0., stop=1., length=q)
ny = 52
nx = 51
xmin, xmax, ymin, ymax = 0.0, 1.0, 0.0, 1.0
xspan = range(xmin, stop=xmax, length=nx)
yspan = range(ymin, stop=ymax, length=ny)
P = AxisArray(SVector{2}.(xspan, yspan'), xspan, yspan)

function compute_double_gyre_tensors(tspan,tol,P)
    mCG_tensor = u -> av_weighted_CG_tensor(rot_double_gyre, u, tspan, tol)
    return map(mCG_tensor, P)
end
T = compute_double_gyre_tensors(tspan,1e-6,P)

@testset "combine singularities" begin
    ξ = map(t -> convert(SVector{2}, eigvecs(t)[:,1]), T)
    singularities = @inferred compute_singularities(ξ, p1dist)
    new_singularities = @inferred combine_singularities(singularities, 3*step(xspan))
    @inferred CoherentStructures.combine_20(new_singularities)
    r₁ , r₂ = 2*rand(2)
    @test sum(getindices(combine_singularities(singularities, r₁))) ==
        sum(getindices(combine_singularities(singularities, r₂))) ==
        sum(getindices(combine_singularities(singularities, 2)))
end

@testset "closed orbit detection" begin
    Ω = SMatrix{2,2}(0, 1, -1, 0)
    vf(λ) = OrdinaryDiffEq.ODEFunction((u, p, t) -> (Ω - (1 - λ) * I) * u)
    seed = SVector{2}(rand(), 0)
    d = @inferred CS.Poincaré_return_distance(vf(1), seed)
    @test d ≈ 0 atol = 1e-5
    λ⁰ = (@inferred CS.bisection(λ -> CS.Poincaré_return_distance(vf(λ), seed), 0.7, 1.4, 1e-6, 40))[2]
    @test λ⁰ ≈ 1 rtol=1e-3
end

@testset "ellipticLCS" begin
    q = @inferred LCSParameters()
    @test q isa LCSParameters
    # p = @inferred LCSParameters(3*max(step(xspan), step(yspan)), 0.5, true, 60, 0.7, 1.5, 1e-4)
    p = @inferred LCSParameters(0.5)
    @test p isa LCSParameters
    cache = @inferred CS.orient(T, SVector{2}(0.25, 0.5))
    @test cache isa CS.LCScache
    vortices, singularities = ellipticLCS(T, p; outermost=true, verbose=false)
    @test sum(map(v -> length(v.barriers), vortices)) == 2
    @test singularities isa Vector{Singularity{Float64}}
    @test length(singularities) > 5
    vortices, _ = ellipticLCS(T, p; outermost=false, verbose=false)
    @test sum(map(v -> length(v.barriers), vortices)) > 20
end

@testset "constrainedLCS" begin
    Ω = SMatrix{2,2}(0, 1, -1, 0)
    Z = zeros(SVector{2})
    for (nx, ny) in ((50, 50), (51, 51), (50, 51), (51, 50)), combine in (true, false), scaling in [-1,1]
        xspan = range(-1, stop=1, length=nx)
        yspan = range(-1, stop=1, length=ny)
        P = AxisArray(SVector{2}.(xspan, yspan'), xspan, yspan)
        q = map(p -> iszero(p) ? ones(typeof(p)) : scaling*(Ω + I) * normalize(p), P)
        if combine
            merge_heuristics=[combine_20]
        else
            merge_heuristics=Any[]
        end
        p = @inferred LCSParameters(1.0, 3*max(step(xspan), step(yspan)), merge_heuristics, 60, 0.5, 1.5, 1e-4)

        vortices, singularities = constrainedLCS(q, p; outermost=true, verbose=false,debug=false)
        @test sum(map(v -> length(v.barriers), vortices)) == 1
        @test singularities isa Vector{Singularity{Float64}}
        @test vortices[1].center ≈ Z atol=max(step(xspan), step(yspan))
        @test length(singularities) == 1
        @test singularities[1].coords ≈ Z atol=max(step(xspan), step(yspan))

        vortices, singularities = constrainedLCS(q, p; outermost=false, verbose=false,debug=false)
        @test sum(map(v -> length(v.barriers), vortices)) > 1
        @test singularities isa Vector{Singularity{Float64}}
        @test length(singularities) == 1
        @test singularities[1].coords ≈ Z atol=max(step(xspan), step(yspan))
    end
end
