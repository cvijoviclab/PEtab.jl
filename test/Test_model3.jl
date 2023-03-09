#=
    Check the accruacy of the PeTab importer for a simple linear ODE;
    x' = a - bx + cy; x(0) = 0
    y' = bx - cy - dy;  y(0) = 0
    where the model has a pre-equilibrium condition. That is he simulated data for
    this ODE model is generated by starting from the steady state;
    x* = a / b + ( a * c ) / ( b * d )
    y* = a / d
    and when computing the cost in the PeTab importer the model is first simualted
    to a steady state, and then the mian simulation matched against data is
    performed.
    This test compares the ODE-solution, cost, gradient and hessian when
    i) solving the ODE using the SS-equations as initial condition, and ii) when
    first simulating the model to the steady state.
    Accruacy of both the hessian and gradient are strongly dependent on the tolerances
    used in the TerminateSteadyState callback.
 =#


using PEtab
using Test
using OrdinaryDiffEq
using SciMLSensitivity
using CSV
using DataFrames
using ForwardDiff
using LinearAlgebra
using Sundials

import PEtab: readPEtabFiles, processMeasurements, processParameters, computeIndicesθ, processSimulationInfo, setParamToFileValues!
import PEtab: _changeExperimentalCondition!, solveODEAllExperimentalConditions


include(joinpath(@__DIR__, "Common.jl"))


function getSolAlgebraicSS(petabModel::PEtabModel, solver, tol::Float64, a::T1, b::T1, c::T1, d::T1) where T1<:Real

    # ODE solution with algebraically computed initial values (instead of ss pre-simulation)
    odeProb = ODEProblem(petabModel.odeSystem, petabModel.stateMap, (0.0, 9.7), petabModel.parameterMap, jac=true)
    odeProb = remake(odeProb, p = convert.(eltype(a), odeProb.p), u0 = convert.(eltype(a), odeProb.u0))
    solArray = Array{ODESolution, 1}(undef, 2)

    # Set model parameter values to ensure initial steady state
    odeProb.p[5], odeProb.p[3], odeProb.p[1], odeProb.p[6] = a, b, c, d
    odeProb.u0[1] = a / b + ( a * c ) / ( b * d ) # x0
    odeProb.u0[2] = a / d # y0

    odeProb.p[4] = 2.0 # a_scale
    solArray[1] = solve(odeProb, solver, abstol=tol, reltol=tol)
    odeProb.p[4] = 0.5 # a_scale
    solArray[2] = solve(odeProb, solver, abstol=tol, reltol=tol)

    return solArray
end


function computeCostAlgebraic(paramVec, petabModel, solver, tol)

    a, b, c, d = paramVec

    experimentalConditionsFile, measurementDataFile, parameterDataFile, observablesDataFile = readPEtabFiles(petabModel)
    measurementData = processMeasurements(measurementDataFile, observablesDataFile)

    solArrayAlg = getSolAlgebraicSS(petabModel, solver, tol, a, b, c, d)
    logLik = 0.0
    for i in eachindex(measurementData.time)
        yObs = measurementData.measurement[i]
        t = measurementData.time[i]
        if measurementData.simulationConditionId[i] == :double
            yMod = solArrayAlg[1](t)[1]
        else
            yMod = solArrayAlg[2](t)[2]
        end
        sigma = 0.04
        logLik += log(sigma) + 0.5*log(2*pi) + 0.5 * ((yObs - yMod) / sigma)^2
    end

    return logLik
end


function testODESolverTestModel3(petabModel::PEtabModel, solverOptions::ODESolverOptions)

    # Set values to PeTab file values
    experimentalConditionsFile, measurementDataFile, parameterDataFile, observablesDataFile = readPEtabFiles(petabModel)
    measurementData = processMeasurements(measurementDataFile, observablesDataFile)
    paramData = processParameters(parameterDataFile)
    setParamToFileValues!(petabModel.parameterMap, petabModel.stateMap, paramData)
    θ_indices = computeIndicesθ(paramData, measurementData, petabModel.odeSystem, experimentalConditionsFile)

    # Extract experimental conditions for simulations
    simulationInfo = processSimulationInfo(petabModel, measurementData, absTolSS=1e-12, relTolSS=1e-10)

    # Parameter values where to teast accuracy. Each column is a alpha, beta, gamma and delta
    # a, b, c, d
    parametersTest = reshape([1.0, 2.0, 3.0, 4.0,
                              0.1, 0.2, 0.3, 0.4,
                              4.0, 3.0, 2.0, 1.0,
                              1.0, 1.0, 1.0, 1.0,
                              2.5, 7.0, 3.0, 3.0,], (4, 5))

    for i in 1:5
        a, b, c, d = parametersTest[:, i]
        # Set parameter values for ODE
        petabModel.parameterMap[1] = Pair(petabModel.parameterMap[1].first, c)
        petabModel.parameterMap[3] = Pair(petabModel.parameterMap[3].first, b)
        petabModel.parameterMap[5] = Pair(petabModel.parameterMap[5].first, a)
        petabModel.parameterMap[6] = Pair(petabModel.parameterMap[6].first, d)

        prob = ODEProblem(petabModel.odeSystem, petabModel.stateMap, (0.0, 9.7), petabModel.parameterMap, jac=true)
        prob = remake(prob, p = convert.(Float64, prob.p), u0 = convert.(Float64, prob.u0))
        θ_dynamic = getFileODEvalues(petabModel)[1:4]
        petabODESolverCache = createPEtabODESolverCache(:nothing, :nothing, petabModel, simulationInfo, θ_indices, nothing)

        # Solve ODE system
        odeSolutions, success = solveODEAllExperimentalConditions(prob, petabModel, θ_dynamic, petabODESolverCache, simulationInfo, θ_indices, solverOptions)
        # Solve ODE system with algebraic intial values
        algebraicODESolutions = getSolAlgebraicSS(petabModel, solverOptions.solver, solverOptions.abstol, a, b, c, d)

        # Compare against analytical solution
        sqDiff = 0.0
        for i in eachindex(simulationInfo.experimentalConditionId)
            solNum = odeSolutions[simulationInfo.experimentalConditionId[i]]
            solAlg = algebraicODESolutions[i]
            sqDiff += sum((Array(solNum) - Array(solAlg(solNum.t))).^2)
        end

        @test sqDiff ≤ 1e-6
    end
end


function testCostGradientOrHessianTestModel3(petabModel::PEtabModel, solverOptions)

    _computeCostAlgebraic = (pArg) -> computeCostAlgebraic(pArg, petabModel, solverOptions.solver, solverOptions.abstol)

    cube = Matrix(CSV.read(joinpath(@__DIR__, "Test_model3", "Julia_model_files", "CubeTest_model3.csv") , DataFrame))

    for i in 1:1

        p = cube[i, :]

        referenceCost = _computeCostAlgebraic(p)
        referenceGradient = ForwardDiff.gradient(_computeCostAlgebraic, p)
        referenceHessian = ForwardDiff.hessian(_computeCostAlgebraic, p)

        # Test both the standard and Zygote approach to compute the cost
        cost = _testCostGradientOrHessian(petabModel, solverOptions, p, computeCost=true, costMethod=:Standard, solverSSAbsTol=1e-12, solverSSRelTol=1e-10)
        @test cost ≈ referenceCost atol=1e-3
        costZygote = _testCostGradientOrHessian(petabModel, solverOptions, p, computeCost=true, costMethod=:Zygote, solverSSAbsTol=1e-12, solverSSRelTol=1e-10)
        @test costZygote ≈ referenceCost atol=1e-3

        # Test all gradient combinations. Note we test sensitivity equations with and without autodiff
        gradientForwardDiff = _testCostGradientOrHessian(petabModel, solverOptions, p, computeGradient=true, gradientMethod=:ForwardDiff, solverSSAbsTol=1e-12, solverSSRelTol=1e-10)
        @test norm(gradientForwardDiff - referenceGradient) ≤ 1e-2
        gradientZygote = _testCostGradientOrHessian(petabModel, solverOptions, p, computeGradient=true, gradientMethod=:Zygote, sensealg=ForwardDiffSensitivity(), solverSSAbsTol=1e-12, solverSSRelTol=1e-10)
        @test norm(gradientZygote - referenceGradient) ≤ 1e-2
        gradientAdjoint = _testCostGradientOrHessian(petabModel, solverOptions, p, computeGradient=true, gradientMethod=:Adjoint, sensealg=QuadratureAdjoint(autojacvec=ReverseDiffVJP(false)), solverSSAbsTol=1e-12, solverSSRelTol=1e-10)
        @test norm(normalize(gradientAdjoint) - normalize((referenceGradient))) ≤ 1e-2
        gradientForward1 = _testCostGradientOrHessian(petabModel, solverOptions, p, computeGradient=true, gradientMethod=:ForwardEquations, sensealg=:ForwardDiff, solverSSAbsTol=1e-12, solverSSRelTol=1e-10)
        @test norm(gradientForward1 - referenceGradient) ≤ 1e-2
        gradientForward2 = _testCostGradientOrHessian(petabModel, getODESolverOptions(CVODE_BDF(), solverAbstol=1e-12, solverReltol=1e-12), p, computeGradient=true, gradientMethod=:ForwardEquations, sensealg=ForwardSensitivity(), solverSSAbsTol=1e-12, solverSSRelTol=1e-10)
        @test norm(gradientForward2 - referenceGradient) ≤ 1e-2

        # Testing "exact" hessian via autodiff
        hessian = _testCostGradientOrHessian(petabModel, solverOptions, p, computeHessian=true, hessianMethod=:ForwardDiff, solverSSAbsTol=1e-12, solverSSRelTol=1e-10)
        @test norm(hessian - referenceHessian) ≤ 1e-2
    end

    return true
end


petabModel = readPEtabModel(joinpath(@__DIR__, "Test_model3/Test_model3.yaml"), forceBuildJuliaFiles=false)

@testset "ODE solver" begin
    testODESolverTestModel3(petabModel, getODESolverOptions(Rodas4P(), solverAbstol=1e-12, solverReltol=1e-12))
end

@testset "Cost gradient and hessian" begin
    testCostGradientOrHessianTestModel3(petabModel, getODESolverOptions(Rodas4P(), solverAbstol=1e-12, solverReltol=1e-12))
end

@testset "Gradient of residuals" begin
    checkGradientResiduals(petabModel, getODESolverOptions(Rodas4P(), solverAbstol=1e-9, solverReltol=1e-9))
end
