function getODEModel_0018(foo)
    ### Define independent and dependent variables
    ModelingToolkit.@variables t B(t) A(t)

    ### Store dependent variables in array for ODESystem command
    stateArray = [B, A]

    ### Define variable parameters

    ### Define potential algebraic variables

    ### Define parameters
    ModelingToolkit.@parameters compartment c1 b0 k1 a0 k2 __init__B__ __init__A__

    ### Store parameters in array for ODESystem command
    parameterArray = [compartment, c1, b0, k1, a0, k2,  __init__B__, __init__A__]

    ### Define an operator for the differentiation w.r.t. time
    D = Differential(t)

    ### Continious events ###

    ### Discrete events ###

    ### Derivatives ###
    eqs = [
    D(B) ~ (((-compartment)*k2)*B)+((compartment*k1)*A),
    D(A) ~ (k2*B)-(k1*A)
    ]

    @named sys = ODESystem(eqs, t, stateArray, parameterArray)

    ### Initial species concentrations ###
    initialSpeciesValues = [
	B => __init__B__,
	A => __init__A__,
    ]

    ### SBML file parameter values ###
    trueParameterValues = [
	__init__B__ => b0,
	__init__A__ => a0,
    compartment => 1.0,
    c1 => 1.0,
    b0 => 1.0,
    k1 => 0.0,
    a0 => 1.0,
    k2 => 0.0
    ]

    return sys, initialSpeciesValues, trueParameterValues

end

