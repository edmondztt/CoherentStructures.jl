#(c) 2018 Nathanael Schilling
#This file contains code for running numerical experiments with CoherentStructures.jl

using JLD2,StaticArrays,Tensors, LinearMaps, Printf,Arpack

include("testCase.jl")

mutable struct experimentResult
    experiment::testCase
    ctx::CoherentStructures.GridContext
    bdata::BoundaryData
    mode::Symbol #One of :naTO, :aTO, :CG, :L2GTOf : L2GTOb, etc..
    done::Bool
    runtime::Float64
    λ::Vector{Float64}
    V::Array{Float64,2}
    statistics::Dict{String, Any} #Things we can calculate about this solution
    solver
    tolerance::Float64
    δ::Float64

    #Like below, but make boundary data first
    function experimentResult(experiment::testCase,ctx::CoherentStructures.GridContext,mode;tolerance=CoherentStructures.default_tolerance,δ=1e-8,solver=CoherentStructures.default_solver)
        bdata = BoundaryData(ctx,experiment.bdata_predicate, experiment.dbc_facesets)
        result = new(experiment,ctx,bdata,mode,false,-1.0,Vector{Float64}([]),zeros(0,2),Dict{String,Any}(),solver,tolerance,δ)
        return result
    end

    #Constructor from general CoherentStructures.GridContext object
    function experimentResult(experiment::testCase,ctx::CoherentStructures.GridContext,bdata::CoherentStructures.BoundaryData,mode;tolerance=CoherentStructures.default_tolerance,δ=1e-8,solver=CoherentStructures.default_solver)
        result = new(experiment,ctx,bdata,mode,false,-1.0,Vector{Float64}([]),zeros(0,2),Dict{String,Any}(),solver,tolerance,δ)
        return result
    end
    #For regular Grids:
    function experimentResult(experiment::testCase, gridType::String, howmany , mode;tolerance=CoherentStructure.default_tolerance,δ=1e-8,solver=CoherentStructures.default_solver)
        ctx = regularGrid(gridType,howmany, experiment.LL, experiment.UR)
        bdata = BoundaryData(ctx,experiment.bdata_predicate,experiment.dbc_facesets)
        return experimentResult(experiment,ctx,bdata,mode;tolerance=tolerance, solver=solver,δ=δ)
    end

end

function runExperiment!(eR::experimentResult,nev=6)
    if eR.done
        print("Experiment was already run, not running again...")
        return
    end
    eR.runtime = 0.0
    if eR.mode == :CG
        times = [eR.experiment.t_initial,eR.experiment.t_final]
        if eR.experiment.is_ode
            ode_fun = eR.experiment.ode_fun
            #TODO: Th10ink about varying the parameters below.
            cgfun = (x -> mean_diff_tensor(ode_fun,x,times, eR.δ,tolerance=eR.tolerance,p=eR.experiment.p))
        else
            cgfun = x->0.5*(one(SymmetricTensor{2,2,Float64,4}) + dott(inv(eR.experiment.Df(x))))
        end
        eR.runtime += (@elapsed K = assembleStiffnessMatrix(eR.ctx,cgfun,bdata=eR.bdata))
        #TODO:Vary whether or not we lump the mass matrices or not
        eR.runtime += (@elapsed M = assembleMassMatrix(eR.ctx,bdata=eR.bdata,lumped=false))
        eR.runtime +=  (@elapsed λ, v = eigs(-1*K,M,which=:SM,nev=nev))
        eR.λ = λ
        eR.V = v
    elseif eR.mode == :aTO
        if ! isempty(eR.bdata.periodic_dofs_from)
            error("Periodic boundary conditions not yet implemented for adaptive TO")
        end
        times = [eR.experiment.t_initial,eR.experiment.t_final]
        ode_fun = eR.experiment.ode_fun
        if eR.experiment.f != nothing
            forwards_flow = eR.experiment.f
        elseif eR.experiment.is_ode
            forwards_flow = u0->flow(ode_fun, u0,times,p=eR.experiment.p,tolerance=eR.tolerance)[end]
        else
            error("No way to calculate forwards flow")
        end
        eR.runtime += (@elapsed S = assembleStiffnessMatrix(eR.ctx))
        eR.runtime += (@elapsed M = assembleMassMatrix(eR.ctx,bdata=eR.bdata))
        eR.runtime += (@elapsed S2= adaptiveTO(eR.ctx,forwards_flow))
        eR.runtime += (@elapsed R = CoherentStructures.applyBCS(eR.ctx, -0.5*(S+S2),eR.bdata))
        eR.runtime += (@elapsed λ, v = eigs(R,M,which=:SM,nev=nev))
        eR.λ = λ
        eR.V = v
    elseif eR.mode == :naTO
        times = [eR.experiment.t_final,eR.experiment.t_initial]
        ode_fun = eR.experiment.ode_fun
        if eR.experiment.finv != nothing
            backwards_flow = eR.experiment.finv
        elseif eR.experiment.is_ode
            backwards_flow = u0->flow(ode_fun, u0,times,p=eR.experiment.p,tolerance=eR.tolerance)[end]
        else
            error("No way to calculate backwards flow")
        end
        eR.runtime += (@elapsed S = assembleStiffnessMatrix(eR.ctx))
        eR.runtime += (@elapsed M = assembleMassMatrix(eR.ctx,bdata=eR.bdata))
        eR.runtime += (@elapsed ALPHA= nonAdaptiveTO(eR.ctx,backwards_flow))

        eR.runtime += (@elapsed R = CoherentStructures.applyBCS(eR.ctx,-0.5*(S + ALPHA'*S*ALPHA),eR.bdata))
        eR.runtime += (@elapsed λ, v = eigs(0.5(R +R'),M,which=:SM,nev=nev))

        eR.λ = λ
        eR.V = v
    elseif eR.mode == :L2GTOb
        times = [eR.experiment.t_final,eR.experiment.t_initial]
        ode_fun = eR.experiment.ode_fun
        if eR.experiment.finv != nothing
            backwards_flow = eR.experiment.finv
        elseif eR.experiment.is_ode
            backwards_flow = u0->flow(ode_fun, u0,times,p=eR.experiment.p,tolerance=eR.tolerance)[end]
        else
            error("No way to calculate backwards flow")
        end
        eR.runtime += (@elapsed S = assembleStiffnessMatrix(eR.ctx,bdata=eR.bdata))
        eR.runtime += (@elapsed Mfull = assembleMassMatrix(eR.ctx))
        eR.runtime += (@elapsed M = applyBCS(eR.ctx,Mfull,eR.bdata))

        eR.runtime += (@elapsed preALPHA= applyBCS(eR.ctx,L2GalerkinTOFromInverse(eR.ctx,backwards_flow),eR.bdata))

        function mulby(x)
            return -0.5(
                    preALPHA'*(M'\(S*(M\(preALPHA*x)))) + S*x
                    )
        end
        L = LinearMap(mulby,size(M)[1],issymmetric=true)
        eR.runtime += (@elapsed λ, v = eigs(L,M,which=:SR,nev=nev,maxiter=100000000))

        eR.λ = λ
        eR.V = v
    else
        error("Invalid mode")
    end
    eR.done = true
    return eR
end

function plotExperiment(eR::experimentResult,nev=-1; kwargs...)
    if !eR.done
        print("Experiment not yet run")
        return
    end
    #TODO: Can we get rid of the error message from using :rainbow in any other way?
    Plots.clibrary(:misc)
    allplots = []
    for (i,lam) in enumerate(eR.λ)
        if nev != -1 && i > nev
            break
        end
        push!(allplots,plot_u(eR.ctx,real.(eR.V[:,i]),200,200,bdata=eR.bdata,title=(@sprintf("%.2f",lam)),color=:rainbow,colorbar=:none;kwargs...))
    end
    Plots.plot(allplots...,margin=-10Plots.px)
end



#TODO: Think of moving helper functions like these to GridFunctions.jl

function getnorm(u::Vector{T},ctx::CoherentStructures.GridContext,which="L∞", M=nothing) where {T}
    if which == "L∞"
        return maximum(abs.(u))
    elseif which == "L2"
        return sqrt(getInnerProduct(ctx,u,u,M))
    else
        error("Not yet implemented")
    end
end

function getInnerProduct(ctx::CoherentStructures.GridContext, u1::Vector{Float64},u2::Vector{Float64},Min=nothing)
        if Min === nothing
            M = assembleMassMatrix(ctx)
        else
            M = Min
        end
        Mu1 = M*u1
        return  u2 ⋅ Mu1
end

function getInnerProduct(ctx::CoherentStructures.GridContext, u1::Vector{ComplexF64},u2::Vector{ComplexF64},Min=nothing)
        if Min === nothing
            M = assembleMassMatrix(ctx)
        else
            M = Min
        end
        Mu1 = M*u1
        return  conj(u2) ⋅ Mu1
end

function getDiscreteInnerProduct(ctx1::CoherentStructures.GridContext, u1::Vector{Float64}, ctx2::CoherentStructures.GridContext, u2::Vector{Float64},nx=400,ny=400)
    res = 0.0
    for x in range(ctx1.spatialBounds[1][1],stop=ctx1.spatialBounds[2][1],length=nx)
        for y in range(ctx1.spatialBounds[1][2],stop=ctx1.spatialBounds[2][2],length=ny)
            res += evaluate_function_from_dofvals(ctx1,u1,[x,y],outside_value=NaN) * evaluate_function_from_dofvals(ctx2,u2,[x,y],outside_value=NaN)
        end
    end
    return  res/(nx*ny)
end


function accuracyTest(tC::testCase,whichgrids=20:20:200;quadrature_order=CoherentStructures.default_quadrature_order,mode=:CG,tolerance=CoherentStructures.default_tolerance,δ=1e-8)
    #gridConstructors = [regularTriangularGrid, regularDelaunayGrid, regularP2TriangularGrid, regularP2DelaunayGrid , regularQuadrilateralGrid,regularP2QuadrilateralGrid]
    #gridConstructorNames = ["regular triangular grid", "regular Delaunay grid","regular P2 triangular grid", "regular P2 Delaunay grid", "regular quadrilateral grid", "regular P2 quadrilateral grid"]

    experimentResults = experimentResult[]
    gridConstructors = [regularTriangularGrid, regularP2TriangularGrid ]
    gridConstructorNames = ["regular triangular grid", "regular P2 triangular grid" ]
    for (gCindex,gC) in enumerate(gridConstructors)
        if mode ∈ [:aTO] && gCindex == 2
            continue
        end
        if mode == :CG && gCindex == 2 && quadrature_order == 1
            continue
        end
        for width in collect(whichgrids)
            ctx = gC((width,width),tC.LL,tC.UR,quadrature_order=quadrature_order)
            testCaseName = tC.name
            gCName = gridConstructorNames[gCindex]
            print("Running $testCaseName test case on $width×$width $gCName")
            eR = experimentResult(tC, ctx,mode,tolerance=tolerance,δ=δ)
            runExperiment!(eR)
            push!(experimentResults,eR)
        end
    end
    return experimentResults
end

function buildStatistics!(experimentResults::Vector{experimentResult}, referenceIndex::Int64)
    reference = experimentResults[referenceIndex]
    M_ref = assembleMassMatrix(reference.ctx)
    n_experiments = size(experimentResults)[1]
    reference_evs =[]
    for j in 1:6
        index_ref = sortperm(real.(reference.λ))[j]
        ref_ev = undoBCS(reference.ctx, reference.V[:,j],reference.bdata)
        ref_ev /= getnorm(ref_ev,reference.ctx,"L2",M_ref)
        push!(reference_evs,ref_ev)
    end
    for (eRindex, eR) in enumerate(experimentResults)
        print("Building Statistics for run $eRindex/$n_experiments \n")
        linftyerrors = Vector{Float64}([])
        l2errors = Vector{Float64}([])
        λerrors = Vector{Float64}([])
        errors = Array{Array{Float64}}([])

        E = zeros(6,6)
        B = zeros(6,6)
        upsampled_current = []
        for i in 1:6
            index = sortperm(real.(eR.λ))[i]
            upsampled = sample_to(undoBCS(eR.ctx,eR.V[:,index],eR.bdata),eR.ctx,reference.ctx)
            upsampled /= getnorm(upsampled,reference.ctx,"L2",M_ref)
            push!(upsampled_current,upsampled)
            for j in 1:6
                ref_ev = reference_evs[j]
                E[i,j] = getInnerProduct(reference.ctx, ref_ev, upsampled,M_ref)
                if j <= i
                    upsampled_j = upsampled_current[j]
                    B[i,j] = getInnerProduct(reference.ctx, upsampled_j, upsampled,M_ref)
                    B[j,i] = B[i,j]
                end
            end
        end
        #for j in 1:6
        #    index_ref = sortperm(real.(reference.λ))[j]
        #    normIndex_ref = sqrt(getDiscreteInnerProduct(reference.ctx, reference.V[:,index_ref],
        #                                                 reference.ctx, reference.V[:,index_ref],800,800))
        #    for i in 1:6
        #        index = sortperm(real.(eR.λ))[i]
        #        normIndex = sqrt(getDiscreteInnerProduct(eR.ctx, eR.V[:,index], eR.ctx, eR.V[:,index],800,800))
        #        E_discrete[i,j] = getDiscreteInnerProduct(reference.ctx, reference.V[:,index_ref],eR.ctx,eR.V[:,index])/(normIndex_ref*normIndex)
        #    end
        #end
        experimentResults[eRindex].statistics["E"]  = E
        experimentResults[eRindex].statistics["B"]  = B
        #experimentResults[eRindex].statistics["E_discrete"]  = E_discrete
    end
end

function testDoubleGyre(whichgrids;quadrature_order=CoherentStructures.default_quadrature_order,run_reference=true,mode=:CG,tf=1.0)
    tC = makeDoubleGyreTestCase(tf)
    result = experimentResult[]
    if run_reference
        referenceCtx = regularP2TriangularGrid( (513,513), tC.LL,tC.UR,quadrature_order=quadrature_order)
        reference = experimentResult(tC,referenceCtx,:CG,tolerance=1e-5)
        runExperiment!(reference)
        push!(result,reference)
    end
    append!(result,accuracyTest(tC,whichgrids,quadrature_order=quadrature_order,mode=mode,tolerance=1e-5))
    return result
end

function testDoubleGyreEqVari(whichgrids;quadrature_order=CoherentStructures.default_quadrature_order,run_reference=true,mode=:CG,tf=1.0)
    tC = makeDoubleGyreEqVariTestCase(tf)
    result = experimentResult[]
    if run_reference
        referenceCtx = regularP2TriangularGrid( (513,513), tC.LL,tC.UR,quadrature_order=quadrature_order)
        reference = experimentResult(tC,referenceCtx,:CG,tolerance=1e-5,δ=0.0)
        runExperiment!(reference)
        push!(result,reference)
    end
    append!(result,accuracyTest(tC,whichgrids,quadrature_order=quadrature_order,mode=mode,tolerance=1e-5,δ=0.0))
    return result
end


function testStaticLaplace(whichgrids;quadrature_order=CoherentStructures.default_quadrature_order,run_reference=true,mode=:CG)
    tC = makeStaticLaplaceTestCase()
    result = experimentResult[]
    if run_reference
        referenceCtx = regularP2TriangularGrid( (400,400), tC.LL,tC.UR,quadrature_order=5)
        reference = experimentResult(tC,referenceCtx,:CG)
        runExperiment!(reference)
        push!(result,reference)
    end
    append!(result,accuracyTest(tC, whichgrids,quadrature_order=quadrature_order,mode=mode))
    return result
end

function testGeneric(tC, whichgrids; quadrature_order=CoherentStructures.default_quadrature_order,
    run_reference=true,mode=:CG,tolerance=CoherentStructures.default_tolerance
    )
    result = experimentResult[]
    if run_reference
        print("Running reference")
        referenceCtx = regularP2TriangularGrid( (513,513), tC.LL,tC.UR,quadrature_order=5)
        reference = experimentResult(tC,referenceCtx,:CG)
        runExperiment!(reference)
        push!(result,reference)
    end
    append!(result,accuracyTest(tC, whichgrids,quadrature_order=quadrature_order,mode=mode,tolerance=tolerance))
    return result
end

function testStandardMap(
    whichgrids;
    quadrature_order=CoherentStructures.default_quadrature_order,run_reference=true,mode=:CG,
    tolerance=CoherentStructures.default_tolerance
    )
    tC = makeStandardMapTestCase()
    result = experimentResult[]
    if run_reference
        referenceCtx = regularP2TriangularGrid( (513,513), tC.LL,tC.UR,quadrature_order=5)
        reference = experimentResult(tC,referenceCtx,:CG)
        runExperiment!(reference)
        push!(result,reference)
    end
    append!(result,accuracyTest(tC, whichgrids,quadrature_order=quadrature_order,mode=mode,tolerance=tolerance))
    return result
end


function testStandardMap8(
    whichgrids;
    quadrature_order=CoherentStructures.default_quadrature_order,run_reference=true,mode=:CG,
    tolerance=CoherentStructures.default_tolerance
    )
    tC = makeStandardMap8TestCase()
    result = experimentResult[]
    if run_reference
        referenceCtx = regularP2TriangularGrid( (513,513), tC.LL,tC.UR,quadrature_order=5)
        reference = experimentResult(tC,referenceCtx,:CG)
        runExperiment!(reference)
        push!(result,reference)
    end
    append!(result,accuracyTest(tC, whichgrids,quadrature_order=quadrature_order,mode=mode,tolerance=tolerance))
    return result
end



function loglogleastsquareslines(xs_nonlog,ys_nonlog,gridtypes)
    xs = log10.(xs_nonlog)
    ys = log10.(ys_nonlog)

    for g in unique(gridtypes)
        indices = findall(x->x==g,gridtypes)
        xs_cur = xs[indices]
        ys_cur = ys[indices]
        xs_cur_nonlog = xs_nonlog[indices]

        A = hcat(xs_cur,ones(length(xs_cur)))
        G = A'*A
        res  = G \ A'*ys_cur
        legendlabel = [@sprintf("Slope %.2f line", res[1]) for x in xs_cur]
        Plots.display(Plots.plot!(xs_cur_nonlog, 10. .^(res[1] .* xs_cur .+ res[2]),group=legendlabel,color=method_colors[g],linecolor=:match))
    end
end

ev_slopes = Dict("regular P2 triangular grid CG" => 4.0,"regular triangular grid CG"=>2.0,
                    "regular triangular grid naTO" => 2.0, "regular P2 triangular grid naTO" => 2.0,
                    "regular triangular grid L2GTOb" => 2.0, "regular P2 triangular grid L2GTOb" => 2.0
                    )

evec_slopes = Dict("regular P2 triangular grid CG" => 3.0,"regular triangular grid CG"=>2.0,
                    "regular triangular grid naTO" => 2.0, "regular P2 triangular grid naTO" => 2.0,
                    "regular triangular grid L2GTOb" => 2.0, "regular P2 triangular grid L2GTOb" => 2.0
                    )

evec_slopes2 = Dict("regular P2 triangular grid CG" => 2.0,"regular triangular grid CG"=>1.0,
                    "regular triangular grid naTO" => 1.0, "regular P2 triangular grid naTO" => 1.0,
                    "regular triangular grid L2GTOb" => 1.0, "regular P2 triangular grid L2GTOb" => 1.0
                    )
method_colors = Dict("regular P2 triangular grid CG" => :green,"regular triangular grid CG"=>:green,
                    "regular triangular grid naTO" => :blue, "regular P2 triangular grid naTO" => :blue,
                    "regular triangular grid L2GTOb" => :orange, "regular P2 triangular grid L2GTOb" =>:orange
                    )

function loglogslopeline(xs_nonlog,ys_nonlog,gridtypes,slopes;lsq_c=true)
    xs = log10.(xs_nonlog)
    ys = log10.(ys_nonlog)

    for g in unique(gridtypes)
        indices = findall(x->x==g,gridtypes)
        xs_cur = xs[indices]
        ys_cur = ys[indices]
        xs_cur_nonlog = xs_nonlog[indices]
        ys_cur_nonlog = ys_nonlog[indices]


        if lsq_c
            #Do least squares to get c:
            err  =sum([slopes[g]*xs_cur[index] - ys_cur[index] for index in 1:length(xs_cur)])
            c = -err/(length(xs_cur))
        else
            minimal_index = sortperm(xs_cur)[1]
            xs_minimal = xs_cur_nonlog[minimal_index]
            ys_minimal = ys_cur_nonlog[minimal_index]
            c = ys_cur[minimal_index] - slopes[g]*xs_cur[minimal_index]
        end
        legendlabels = ["" for x in xs_cur_nonlog]
        Plots.display(Plots.plot!(xs_cur_nonlog, (10. .^(xs_cur*slopes[g] .+ c)),color=method_colors[g],label=""))
    end
end


using Clustering
function iterated_kmeans(numiterations,args...)
    best = kmeans(args...)
    for i in 1:(numiterations-1)
        cur = kmeans(args...)
        if cur.totalcost < best.totalcost
            print("Improved")
            best = cur
        end
    end
    return best
end
