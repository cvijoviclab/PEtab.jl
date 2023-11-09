"""
    PEtabModel(path_yaml::String;
               build_julia_files::Bool=false,
               verbose::Bool=true,
               ifelse_to_event::Bool=true,
               write_to_file::Bool=true,
               jlfile_path::String="")::PEtabModel

Create a PEtabModel from a PEtab specified problem with a YAML-file located at `path_yaml`.

When parsing a PEtab problem, several things happen under the hood:

1. The SBML file is translated into `ModelingToolkit.jl` format to allow for symbolic computations of the ODE-model Jacobian. Piecewise and model events are further written into `DifferentialEquations.jl` callbacks.
2. The observable PEtab table is translated into a Julia file with functions for computing the observable (`h`), noise parameter (`σ`), and initial values (`u0`).
3. To allow gradients via adjoint sensitivity analysis and/or forward sensitivity equations, the gradients of `h` and `σ` are computed symbolically with respect to the ODE model's states (`u`) and parameters (`ode_problem.p`).

All of this happens automatically, and resulting files are stored under `petab_model.dir_julia` assuming write_to_file=true. To save time, `forceBuildJlFiles=false` by default, which means that Julia files are not rebuilt if they already exist.

# Arguments
- `path_yaml::String`: Path to the PEtab problem YAML file.
- `build_julia_files::Bool=false`: If `true`, forces the creation of Julia files for the problem even if they already exist.
- `verbose::Bool=true`: If `true`, displays verbose output during parsing.
- `ifelse_to_event::Bool=true`: If `true`, rewrites `if-else` statements in the SBML model as event-based callbacks.
- `write_to_file::Bool=true`: If `true`, writes built Julia files to disk (recomended)

# Example
```julia
petab_model = PEtabModel("path_to_petab_problem_yaml")
```
"""
function PEtabModel(path_yaml::String;
                    build_julia_files::Bool=false,
                    verbose::Bool=true,
                    ifelse_to_event::Bool=true,
                    custom_parameter_values::Union{Nothing, Dict}=nothing, 
                    write_to_file::Bool=true)::PEtabModel

    path_SBML, path_parameters, path_conditions, path_observables, path_measurements, dir_julia, dir_model, model_name = read_petab_yaml(path_yaml)

    verbose == true && @info "Building PEtabModel for $model_name"

    path_model_jl_file = joinpath(dir_julia, model_name * ".jl")
    if !isfile(path_model_jl_file) || build_julia_files == true
        verbose == true && printstyled("[ Info:", color=123, bold=true)
        verbose == true && build_julia_files && print(" By user option rebuilds Julia ODE model ...")
        verbose == true && !build_julia_files && print(" Building Julia model file as it does not exist ...")

        b_build = @elapsed model_dict, model_str = SBML_to_ModellingToolkit(path_SBML, path_model_jl_file, model_name, 
            ifelse_to_event=ifelse_to_event, write_to_file=write_to_file)
        verbose == true && @printf(" done. Time = %.1es\n", b_build)
    end

    if isfile(path_model_jl_file) && build_julia_files == false
        verbose == true && printstyled("[ Info:", color=123, bold=true)
        verbose == true && print(" Julia model file exists and will not be rebuilt\n")
        model_str = get_function_str(path_model_jl_file, 1)[1]
    end

    # Check if in order to capture PEtab condition file directly mapping to initial values we have 
    # to rewrite the model parameter to correctly compute gradients etc...
    if !@isdefined(model_dict)
        model_dict, _ = SBML_to_ModellingToolkit(path_SBML, path_model_jl_file, model_name, write_to_file=false, 
                                                 only_extract_model_dict=true, ifelse_to_event=ifelse_to_event)
    end
    change_model_structure = add_parameters_condition_dependent_u0!(model_dict, path_conditions, path_parameters)
    if change_model_structure == true
        model_str = create_ode_model(model_dict, path_model_jl_file, model_name, write_to_file)
    end

    # For down the line processing model dict is required 
    if !@isdefined(model_dict)
        model_dict, _ = SBML_to_ModellingToolkit(path_SBML, path_model_jl_file, model_name, write_to_file=false, 
                                                 only_extract_model_dict=true, ifelse_to_event=ifelse_to_event)
    end

    verbose == true && printstyled("[ Info:", color=123, bold=true)
    verbose == true && print(" Symbolically processes ODE-system ...")
    timeTake = @elapsed begin
        _get_ode_system = @RuntimeGeneratedFunction(Meta.parse(model_str))
        _ode_system, state_map, parameter_map = _get_ode_system("https://xkcd.com/303/") # Argument needed by @RuntimeGeneratedFunction
        if "algebraic_rules" ∉ keys(model_dict) || isempty(model_dict["algebraic_rules"])
            ode_system = structural_simplify(_ode_system)
        # DAE requires special processing
        else
            ode_system = structural_simplify(dae_index_lowering(_ode_system))
        end
        parameter_names = parameters(ode_system)
        state_names = states(ode_system)
    end
    verbose == true && @printf(" done. Time = %.1es\n", timeTake)

    path_u0_h_sigma = joinpath(dir_julia, model_name * "_h_sd_u0.jl")
    if !isfile(path_u0_h_sigma) || build_julia_files == true
        verbose == true && printstyled("[ Info:", color=123, bold=true)
        verbose == true && !isfile(path_u0_h_sigma) && print(" Building u0, h and σ file as it does not exist ...")
        verbose == true && isfile(path_u0_h_sigma) && print(" By user option rebuilds u0, h and σ file ...")
        if !@isdefined(model_dict)
            model_dict, _ = SBML_to_ModellingToolkit(path_SBML, path_model_jl_file, model_name, write_to_file=false, 
                                                     only_extract_model_dict=true, ifelse_to_event=ifelse_to_event)
        end
        b_build = @elapsed h_str, u0!_str, u0_str, σ_str = create_σ_h_u0_file(model_name, path_yaml, dir_julia, ode_system, 
                                                                              parameter_map, state_map, model_dict, 
                                                                              custom_parameter_values=custom_parameter_values, 
                                                                              write_to_file=write_to_file)
        verbose == true && @printf(" done. Time = %.1es\n", b_build)
    else
        verbose == true && printstyled("[ Info:", color=123, bold=true)
        verbose == true && print(" u0, h and σ file exists and will not be rebuilt\n")
        h_str, u0!_str, u0_str, σ_str = get_function_str(path_u0_h_sigma, 4)
    end
    compute_h = @RuntimeGeneratedFunction(Meta.parse(h_str))
    compute_u0! = @RuntimeGeneratedFunction(Meta.parse(u0!_str))
    compute_u0 = @RuntimeGeneratedFunction(Meta.parse(u0_str))
    compute_σ = @RuntimeGeneratedFunction(Meta.parse(σ_str))
    

    path_D_h_sd = joinpath(dir_julia, model_name * "_D_h_sd.jl")
    if !isfile(path_D_h_sd) || build_julia_files == true
        verbose == true && printstyled("[ Info:", color=123, bold=true)
        verbose == true && !isfile(path_u0_h_sigma) && print(" Building ∂h∂p, ∂h∂u, ∂σ∂p and ∂σ∂u file as it does not exist ...")
        verbose == true && isfile(path_u0_h_sigma) && print(" By user option rebuilds ∂h∂p, ∂h∂u, ∂σ∂p and ∂σ∂u file ...")
        if !@isdefined(model_dict)
            model_dict, _ = SBML_to_ModellingToolkit(path_SBML, path_model_jl_file, model_name, write_to_file=false, 
                                                     only_extract_model_dict=true, ifelse_to_event=ifelse_to_event)
        end
        b_build = @elapsed ∂h∂u_str, ∂h∂p_str, ∂σ∂u_str, ∂σ∂p_str = create_derivative_σ_h_file(model_name, path_yaml, 
                                                                                          dir_julia, ode_system, 
                                                                                          parameter_map, state_map, 
                                                                                          model_dict, 
                                                                                          custom_parameter_values=custom_parameter_values, 
                                                                                          write_to_file=write_to_file)
        verbose == true && @printf(" done. Time = %.1es\n", b_build)
    else verbose == true
        verbose == true && printstyled("[ Info:", color=123, bold=true)
        verbose == true && print(" ∂h∂p, ∂h∂u, ∂σ∂p and ∂σ∂u file exists and will not be rebuilt\n")
        ∂h∂u_str, ∂h∂p_str, ∂σ∂u_str, ∂σ∂p_str = get_function_str(path_D_h_sd, 4)
    end
    compute_∂h∂u! = @RuntimeGeneratedFunction(Meta.parse(∂h∂u_str))
    compute_∂h∂p! = @RuntimeGeneratedFunction(Meta.parse(∂h∂p_str))
    compute_∂σ∂σu! = @RuntimeGeneratedFunction(Meta.parse(∂σ∂u_str))
    compute_∂σ∂σp! = @RuntimeGeneratedFunction(Meta.parse(∂σ∂p_str))

    path_callback = joinpath(dir_julia, model_name * "_callbacks.jl")
    if !isfile(path_callback) || build_julia_files == true
        verbose == true && printstyled("[ Info:", color=123, bold=true)
        verbose == true && !isfile(path_callback) && print(" Building callback file as it does not exist ...")
        verbose == true && isfile(path_callback) && print(" By user option rebuilds callback file ...")
        if !@isdefined(model_dict)
            model_dict, _ = SBML_to_ModellingToolkit(path_SBML, path_model_jl_file, model_name, write_to_file=false, 
                only_extract_model_dict=true, ifelse_to_event=ifelse_to_event)
        end
        b_build = @elapsed callback_str, tstops_str = create_callbacks_SBML(ode_system, parameter_map, 
            state_map, model_dict, model_name, path_yaml, dir_julia, custom_parameter_values=custom_parameter_values, 
            write_to_file=write_to_file)
        verbose == true && @printf(" done. Time = %.1es\n", b_build)
    else
        verbose == true && printstyled("[ Info:", color=123, bold=true)
        verbose == true && print(" Callback file exists and will not be rebuilt\n")
        callback_str, tstops_str = get_function_str(path_callback, 2)
    end
    get_callback_function = @RuntimeGeneratedFunction(Meta.parse(callback_str))
    cbset, check_cb_active, convert_tspan = get_callback_function("https://xkcd.com/2694/") # Argument needed by @RuntimeGeneratedFunction
    compute_tstops = @RuntimeGeneratedFunction(Meta.parse(tstops_str))

    petab_model = PEtabModel(model_name,
                             compute_h,
                             compute_u0!,
                             compute_u0,
                             compute_σ,
                             compute_∂h∂u!,
                             compute_∂σ∂σu!,
                             compute_∂h∂p!,
                             compute_∂σ∂σp!,
                             compute_tstops,
                             convert_tspan,
                             ode_system,
                             parameter_map,
                             state_map,
                             parameter_names,
                             state_names,
                             dir_model,
                             dir_julia,
                             CSV.File(path_measurements, stringtype=String),
                             CSV.File(path_conditions, stringtype=String),
                             CSV.File(path_observables, stringtype=String),
                             CSV.File(path_parameters, stringtype=String),
                             path_SBML,
                             path_yaml,
                             cbset,
                             check_cb_active, 
                             false)

    return petab_model
end


# For reading the run-time generated PEtab-related functions which via Meta.parse are passed
# on to @RuntimeGeneratedFunction to build the PEtab related functions without world-problems.
function get_function_str(file_path::AbstractString, n_functions::Int64)::Vector{String}

    f_start, f_end = zeros(Int64, n_functions), zeros(Int64, n_functions)
    i_function = 1
    in_function::Bool = false
    n_lines = open(file_path, "r") do f countlines(f) end
    body_str = Vector{String}(undef, n_lines)

    f = open(file_path, "r")
    for (i_line, line) in pairs(readlines(f))

        if length(line) ≥ 8 && line[1:8] == "function"
            f_start[i_function] = i_line
            in_function = true
        end

        if length(line) ≥ 3 && line[1] != '#' && line[1:3] == "end"
            f_end[i_function] = i_line
            in_function = false
            i_function += 1
        end

        body_str[i_line] = string(line)
    end
    close(f)

    out = Vector{String}(undef, n_functions)
    for i in eachindex(out)

        # Runtime generated functions requrie at least on function argument input, hence if missing we
        # add a foo argument
        if body_str[f_start[i]][end-1:end] == "()"
            body_str[f_start[i]] = body_str[f_start[i]][1:end-2] * "(foo)"
        end

        out[i] = prod([body_str[j] * '\n' for j in f_start[i]:f_end[i]])
    end
    return out
end


function add_parameters_condition_dependent_u0!(SBML_dict::Dict, 
                                                path_conditions::String, 
                                                path_parameters::String)::Bool

    # Load necessary data
    experimental_conditions_file = CSV.File(path_conditions)
    parameters_file = CSV.File(path_parameters)

    parameter_names = [p for p in keys(SBML_dict["parameters"])]
    specie_names = [s for s in keys(SBML_dict["species"])]

    # Check if the condition table contains states to map initial values
    condition_variables = string.(experimental_conditions_file.names)
    if length(condition_variables) == 1
        return false # Model file is not modified 
    end
    i_start = condition_variables[2] == "conditionName" ? 3 : 2 # Sometimes PEtab file does not include column conditionName
    if any(name -> name ∈ specie_names, condition_variables[i_start:end]) == false
        return false # Model file is not modifed
    end

    # Find states and create new parameter names and values
    which_species = (condition_variables[i_start:end])[findall(x -> x ∈ specie_names, condition_variables[i_start:end])]
    # The parameter value is given by the value in the file
    for specie in which_species
        _name = "__init__" .* specie .* "__"
        _value = SBML_dict["species"][specie].initial_value
        _parameter = ParameterSBML(_name, true, _value, "", false, false, false)
        SBML_dict["parameters"][_name] = _parameter
        # Reassign initial value for specie
        SBML_dict["species"][specie].initial_value = _name
    end
    # Do the same thing for rate-rule parameters
    rate_rule_parameters = filter(x -> x != "", [p.rate_rule ? p.name : "" for p in values(SBML_dict["parameters"])])
    which_parameters = (condition_variables[i_start:end])[findall(x -> x ∈ rate_rule_parameters, condition_variables[i_start:end])]
    for parameter in which_parameters
        _name = "__init__" .* parameter .* "__"
        _value = SBML_dict["parameters"][parameter].initial_value
        _parameter = ParameterSBML(_name, true, _value, "", false, false, false)
        SBML_dict["parameters"][_name] = _parameter
        # Reassign initial value for specie
        SBML_dict["parameters"][parameter].initial_value = _name
    end


    # Check if the columns for which the species in conditions file map to parameters 
    # that are not a part of the SBML model as these parameters must then be added to 
    # the model as they should be treated as dynamic parameters 
    for specie in vcat(which_species, which_parameters)
        for row in experimental_conditions_file[Symbol(specie)]
            if typeof(row) <: Real
                continue
            elseif ismissing(row)
                continue
            elseif is_number(row) == true || string(row) ∈ parameter_names
                continue
            # Must be a parameter which did not appear in the SBML file - and thus should be added 
            # to the ODE system so it is treated as a dynamic parameter through the simulations 
            elseif row ∈ parameters_file[:parameterId]
                SBML_dict["parameters"][row] = ParameterSBML(row, true, "0.0", "", false, false, false) 
            else
                @error "The condition table value $row_value does not correspond to any parameter in the SBML file parameters file"
            end
        end
    end

    return true
end
