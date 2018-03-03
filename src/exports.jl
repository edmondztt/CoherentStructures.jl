export
	#PullbackTensors.jl
	flow,
	linearized_flow,
	invCGTensor,
	pullback_tensors,
	pullback_metric_tensor,
	pullback_diffusion_tensor,

	#velocityFields.jl
	rot_double_gyre2!,
	transientGyresEqVari,
	bickleyJetEqVari,
	interpolateVF,
	oceanVF,
	interp_rhs,
	bickleyJet,
	transientGyres,

	#GridFunctions.jl
	regularTriangularGrid,
	regularDelaunayGrid,
	regularP2TriangularGrid,
	regularP2DelaunayGrid,
	regularQuadrilateralGrid,
	regularP2QuadrilateralGrid,
	regularGrid,
	evaluate_function,
	locatePoint,
	nodal_interpolation,

	#plotting.jl
	plot_u,
	plot_spectrum,
	plot_u_eulerian,

	#FEMassembly.jl
	assembleStiffnessMatrix,
	assembleMassMatrix,

	#TO.jl
	nonAdaptiveTO,
	adaptiveTO,
	L2GalerkinTO,

	#numericalExperimens.jl
	makeOceanFlowTestCase,
	makeDoubleGyreTestCase,
	experimentResult,
	runExperiment!,
	plotExperiment,

	#util.jl
	dof2U,

	#advection_diffusion.jl
	ADimplicitEulerStep,

	#field_from_hamiltonian.jl
	@makefields
