using Test

# Data structure for a framework; user-friendly constructor below
struct Framework
    name::AbstractString
    box::Box
    atoms::Atoms
    charges::Charges
    symmetry::Array{AbstractString, 2}
    space_group::AbstractString
    is_p1::Bool
end

"""
    framework = Framework(filename, check_charge_neutrality=true,
                          net_charge_tol=0.001, check_atom_and_charge_overlap=true,
                          remove_overlap=false)
    framework = Framework(name, box, atoms, charges, symmetry, space_group, is_p1)

Read a crystal structure file (.cif or .cssr) and populate a `Framework` data structure,
or construct a `Framework` data structure directly.

# Arguments
- `filename::AbstractString`: the name of the crystal structure file (include ".cif" or ".cssr") read from `joinpath(PorousMaterials.PATH_TO_DATA, "structures")`.
- `check_charge_neutrality::Bool`: check for charge neutrality
- `net_charge_tol::Float64`: when checking for charge neutrality, throw an error if the absolute value of the net charge is larger than this value.
- `check_atom_and_charge_overlap::Bool`: throw an error if overlapping atoms are detected.
- `remove_overlap::Bool`: remove identical atoms automatically. Identical atoms are the same element atoms which overlap.
- `convert_to_p1::Bool`: If the structure is not in P1 it will be converted to
    P1 symmetry using the symmetry rules

# Returns
- `framework::Framework`: A framework containing the crystal structure information

# Attributes
- `name::AbstractString`: name of crystal structure
- `box::Box`: unit cell (Bravais Lattice)
- `atoms::Atoms`: list of Atoms in crystal unit cell
- `charges::Charges`: list of point charges in crystal unit cell
- `symmetry::Array{Function, 2}`: 2D array of anonymous functions that represent
    the symmetry operations. If the structure is in P1 there will be one
    symmetry operation.
- `is_p1::Bool`: Stores whether the framework is currently in P1 symmetry. This
    is used before any simulations such as GCMC and Henry Coefficient
"""
function Framework(filename::AbstractString; check_charge_neutrality::Bool=true,
                   net_charge_tol::Float64=0.001, check_atom_and_charge_overlap::Bool=true,
                   remove_overlap::Bool=false, convert_to_p1::Bool=true)
    # Read file extension. Ensure we can read the file type
    extension = split(filename, ".")[end]
    if ! (extension in ["cif", "cssr"])
        error("PorousMaterials.jl can only read .cif or .cssr crystal structure files.")
    end

    # read file
    f = open(joinpath(PATH_TO_DATA, "crystals", filename), "r")
    lines = readlines(f)
    close(f)

    # Initialize arrays. We'll populate them when reading through the crystal structure file.
    charge_values = Array{Float64, 1}()
    species = Array{Symbol, 1}()
    xf = Array{Float64, 1}()
    yf = Array{Float64, 1}()
    zf = Array{Float64, 1}()
    coords = Array{Float64, 2}(undef, 3, 0)
    # default for symmetry rules is P1.
    # These will be overwritten if the user chooses to read in non-P1
    symmetry_rules = Array{AbstractString, 2}(undef, 3, 0)
    # used for remembering whether fractional/cartesian coordinates are read in
    # placed here so it will be defined for the if-stmt after the box is defined
    fractional = false
    cartesian = false
    # used for determining if the framework is in P1 symmetry for simulations
    p1_symmetry = false
    space_group = ""


    # Start of .cif reader
    if extension == "cif"
        coords_simple = Array{Float64, 2}(undef, 3, 0)
        charges_simple = Array{Float64, 1}()
        species_simple = Array{Symbol, 1}()
        data = Dict{AbstractString, Float64}()
        loop_starts = -1
        i = 1
        # used for reading in symmetry options and replications
        symmetry_info = false
        atom_info = false
        while i <= length(lines)
            line = split(lines[i])
            # Skip empty lines
            if length(line) == 0
                i += 1
                continue
            end

            # Make sure the space group is P1
            if line[1] == "_symmetry_space_group_name_H-M"
                # use anonymous function to combine all terms past the first
                #   to extract space group name
                space_group = reduce((x, y) -> x * " " * y, line[2:end])
                space_group = split(space_group, [''', '"'], keepempty=false)[1]
                if space_group == "P1" || space_group == "P 1" ||
                        space_group == "-P1"
                    # simplify by only having one P1 space_group name
                    space_group = "P1"
                    p1_symmetry = true
                end
            end

            # checking for information about atom sites and symmetry
            if line[1] == "loop_"
                next_line = split(lines[i+1], [' ', '\t']; keepempty=false)
                # only read in symmetry if the structure is not in P1 symmetry
                if occursin("_symmetry_equiv_pos", next_line[1]) && !p1_symmetry
                    symmetry_info = true
                    symmetry_column_name = ""
                    # name_to_column is a dictionary that e.g. returns which column contains xyz remapping
                    #   use example: name_to_column["_symmetry_equiv_pos_as_xyz"] gives 2
                    name_to_column = Dict{AbstractString, Int}()

                    i += 1
                    loop_starts = i
                    while length(split(lines[i], [''', ' ', '\t', ','], keepempty=false)) == 1
                        name_to_column[split(lines[i])[1]] = i + 1 - loop_starts
                        # iterate to next line in file
                        i += 1
                    end

                    @assert haskey(name_to_column, "_symmetry_equiv_pos_as_xyz") "Need column name `_symmetry_equiv_pos_xyz` to parse symmetry information"

                    symmetry_count = 0
                    # CSD stores symmetry as one column in a string that ends
                    #   up getting split on the spaces between commas (i.e. its
                    #   not really one column) the length(name_to_column) + 2
                    #   should catch this hopefully there aren't other weird
                    #   ways of writing cifs...
                    while i <= length(lines) && length(lines[i]) > 0 && lines[i][1] != '_' && !occursin("loop_", lines[i])
                        symmetry_count += 1
                        line = lines[i]
                        sym_funcs = split(line, [' ', ',', '''], keepempty=false)

                        # store as strings so it can be written out later
                        new_sym_rule = Array{AbstractString, 1}(undef, 3)

                        sym_start = name_to_column["_symmetry_equiv_pos_as_xyz"] - 1
                        for j = 1:3
                            new_sym_rule[j] = sym_funcs[j + sym_start]
                        end

                        symmetry_rules = [symmetry_rules new_sym_rule]

                        i += 1
                    end

                    @assert symmetry_count == size(symmetry_rules, 2) "number of symmetry rules must match the count"

                    # finish reading in symmetry information, skip to next
                    #   iteration of outer while-loop
                    continue
                # read in keywords, store in a dictionary, then if
                #   `_atom_site_fract_.` or `_atom_site_Cartn_.` it will
                #   proceed to read in atom coordinate information
                elseif ! atom_info
                    atom_column_name = ""
                    # name_to_column is a dictionary that e.g. returns which column contains x fractional coord
                    #   use example: name_to_column["_atom_site_fract_x"] gives 3
                    name_to_column = Dict{AbstractString, Int}()

                    i += 1
                    loop_starts = i
                    while length(split(lines[i])) == 1 && split(lines[i])[1][1] == '_'
                        if i == loop_starts
                            atom_column_name = split(lines[i])[1]
                        end
                        name_to_column[split(lines[i])[1]] = i + 1 - loop_starts
                        # iterate to next line in file
                        i += 1
                    end

                    # if the file provides fractional coordinates
                    fractional = haskey(name_to_column, "_atom_site_fract_x") &&
                                    haskey(name_to_column, "_atom_site_fract_y") &&
                                    haskey(name_to_column, "_atom_site_fract_z")
                    # if the file provides cartesian coordinates
                    cartesian = haskey(name_to_column, "_atom_site_Cartn_x") &&
                                    haskey(name_to_column, "_atom_site_Cartn_y") &&
                                    haskey(name_to_column, "_atom_site_Cartn_z") &&
                                    ! fractional # if both are provided, will default
                                                 #  to using fractional, so keep cartesian
                                                 #  false
                    if fractional || cartesian
                        # found the atom_info, so don't need to check for it
                        #   after reading in the information
                        atom_info = true
                        # read in atom_site info and store it in column based on
                        #   the name_to_column dictionary
                        while i <= length(lines) && length(split(lines[i])) == length(name_to_column)
                            line = split(lines[i])

                            push!(species_simple, Symbol(line[name_to_column[atom_column_name]]))
                            if fractional
                                coords_simple = [coords_simple [mod(parse(Float64, split(line[name_to_column["_atom_site_fract_x"]], '(')[1]), 1.0),
                                        mod(parse(Float64, split(line[name_to_column["_atom_site_fract_y"]], '(')[1]), 1.0),
                                        mod(parse(Float64, split(line[name_to_column["_atom_site_fract_z"]], '(')[1]), 1.0)]]
                            elseif cartesian
                                coords_simple = [coords_simple [parse(Float64, split(line[name_to_column["_atom_site_Cartn_x"]], '(')[1]),
                                        parse(Float64, split(line[name_to_column["_atom_site_Cartn_y"]], '(')[1]),
                                        parse(Float64, split(line[name_to_column["_atom_site_Cartn_z"]], '(')[1])]]
                            else
                                error("The file does not store atom information in the form '_atom_site_fract_x' or '_atom_site_Cartn_x'")
                            end
                            # If charges present, import them
                            if haskey(name_to_column, "_atom_site_charge")
                                push!(charges_simple, parse(Float64, line[name_to_column["_atom_site_charge"]]))
                            else
                                push!(charges_simple, 0.0)
                            end
                            # iterate to next line in file
                            i += 1
                        end

                        # finish reading in atom_site information, skip to next
                        #   iteration of outer while-loop
                        # prevents skipping a line after finishing reading atoms
                        continue
                    end
                end
            end

            # pick up unit cell lengths
            for axis in ["a", "b", "c"]
                if line[1] == @sprintf("_cell_length_%s", axis)
                    data[axis] = parse(Float64, split(line[2],'(')[1])
                end
            end

            # pick up unit cell angles
            for angle in ["alpha", "beta", "gamma"]
                if line[1] == @sprintf("_cell_angle_%s", angle)
                    data[angle] = parse(Float64, split(line[2],'(')[1]) * pi / 180.0
                end
            end

            i += 1
        end # End loop over lines

        if !atom_info
            error("Could not find _atom_site* after loop_ in .cif file\n")
        end

        # Structure must either be in P1 symmetry or have replication information
        if !p1_symmetry && !symmetry_info
            error("If structure is not in P1 symmetry it must have replication information")
        end

        # warning that structure is not being converted to P1 symmetry
        if ! convert_to_p1 && ! p1_symmetry
            @warn @sprintf("%s is not in P1 symmetry and it is not being converted to P1 symmetry.\nAny simulations performed with PorousMaterials will NOT be accurate",
                          filename)
        end

        a = data["a"]
        b = data["b"]
        c = data["c"]
        α = data["alpha"]
        β = data["beta"]
        γ = data["gamma"]

        # redo coordinates if they were read in cartesian
        if cartesian && ! fractional
            coords_simple = Box(a, b, c, α, β, γ).c_to_f * coords_simple
        end

        if symmetry_info && convert_to_p1
            @warn @sprintf("%s is not in P1 symmetry. It is being converted to P1 for use in PorousMaterials.jl.", filename)
            # loop over all symmetry rules
            for i in 1:size(symmetry_rules, 2)
                new_col = Array{Float64, 1}(undef, 0)
                # loop over all atom positions from lower level symmetry
                for j in 1:size(coords_simple, 2)
                    coords = [coords [Base.invokelatest(eval(Meta.parse("(x, y, z) -> " * symmetry_rules[k, i])), coords_simple[:, j]...) for k in 1:3]]
                end
                charge_values = [charge_values; charges_simple]
                species = [species; species_simple]
            end
        elseif p1_symmetry || !convert_to_p1
            coords = deepcopy(coords_simple)
            charge_values = deepcopy(charges_simple)
            species = deepcopy(species_simple)
        end

        # either read in P1 or converted to P1 so should have same symmetry rules
        if p1_symmetry || convert_to_p1
            symmetry_rules = [Array{AbstractString, 2}(undef, 3, 0) ["x", "y", "z"]]
        end

        # if structure was stored in P1 or converted to P1, store that information for later
        p1_symmetry = p1_symmetry || convert_to_p1

    # Start of cssr reader #TODO make sure this works for different .cssr files!
    elseif extension == "cssr"
        # First line contains unit cell lenghts
        line = split(lines[1])
        a = parse(Float64, line[1])
        b = parse(Float64, line[2])
        c = parse(Float64, line[3])

        # Second line contains unit cell angles
        line = split(lines[2])
        α = parse(Float64, line[1]) * pi / 180.0
        β = parse(Float64, line[2]) * pi / 180.0
        γ = parse(Float64, line[3]) * pi / 180.0

        n_atoms = parse(Int, split(lines[3])[1])

        # Read in atoms and fractional coordinates
        for i = 1:n_atoms
            line = split(lines[4 + i])
            push!(species, Symbol(line[2]))

            push!(xf, mod(parse(Float64, line[3]), 1.0)) # Wrap to [0,1]
            push!(yf, mod(parse(Float64, line[4]), 1.0)) # Wrap to [0,1]
            push!(zf, mod(parse(Float64, line[5]), 1.0)) # Wrap to [0,1]

            push!(charge_values, parse(Float64, line[14]))
        end

        for i = 1:n_atoms
            coords = [ coords [xf[i], yf[i], zf[i]] ]
        end

        # add P1 symmetry rules for consistency
        symmetry_rules = [symmetry_rules ["x", "y", "z"]]
        p1_symmetry = true
        space_group = "P1"
    end

    # Construct the unit cell box
    box = Box(a, b, c, α, β, γ)
    # construct atoms attribute of framework
    atoms = Atoms(species, coords)
    # construct charges attribute of framework; include only nonzero charges
    idx_nz = charge_values .!= 0.0
    charges = Charges(charge_values[idx_nz], coords[:, idx_nz])

    framework = Framework(filename, box, atoms, charges, symmetry_rules, space_group, p1_symmetry)

    if check_charge_neutrality
        if ! charge_neutral(framework, net_charge_tol)
            error(@sprintf("Framework %s is not charge neutral; net charge is %f e. Ignore
            this error message by passing check_charge_neutrality=false or increasing the
            net charge tolerance `net_charge_tol`\n",
                            framework.name, total_charge(framework)))
        end
    end

    strip_numbers_from_atom_labels!(framework)

    if remove_overlap
        return remove_overlapping_atoms_and_charges(framework)
    end

    if check_atom_and_charge_overlap
        if atom_overlap(framework) | charge_overlap(framework)
            error(@sprintf("At least one pair of atoms/charges overlap in %s.
            Consider passing `remove_overlap=true`\n", framework.name))
        end
    end

    return framework
end

"""
    replicated_frame = replicate(framework, repfactors)

Replicates the atoms and charges in a `Framework` in positive directions to
construct a new `Framework`. Note `replicate(framework, (1, 1, 1))` returns the same `Framework`.

# Arguments
- `framework::Framework`: The framework to replicate
- `repfactors::Tuple{Int, Int, Int}`: The factors by which to replicate the crystal structure in each direction.

# Returns
- `replicated_frame::Framework`: Replicated framework
"""
function replicate(framework::Framework, repfactors::Tuple{Int, Int, Int})
    # determine number of atoms in replicated framework
    n_atoms = size(framework.atoms.xf, 2) * repfactors[1] * repfactors[2] * repfactors[3]

    # replicate box
    new_box = replicate(framework.box, repfactors)

    # replicate atoms and charges
    charge_coords = Array{Float64, 2}(undef, 3, 0)
    charge_vals = Array{Float64, 1}()
    atom_coords = Array{Float64, 2}(undef, 3, 0)
    species = Array{Symbol, 1}()
    for ra = 0:(repfactors[1] - 1), rb = 0:(repfactors[2] - 1), rc = 0:(repfactors[3] - 1)
        for i = 1:framework.atoms.n_atoms
            xf = framework.atoms.xf[:, i] + 1.0 * [ra, rb, rc]
            # scale fractional coords
            xf = xf ./ repfactors
            atom_coords = [atom_coords xf]
            push!(species, Symbol(framework.atoms.species[i]))
        end
        for j = 1:framework.charges.n_charges
            xf = framework.charges.xf[:, j] + 1.0 * [ra, rb, rc]
            # scale fractional coords
            xf = xf ./ repfactors
            charge_coords = [charge_coords xf]
            push!(charge_vals, framework.charges.q[j])
        end
    end

    new_atoms = Atoms(species, atom_coords)
    new_charges = Charges(charge_vals, charge_coords)

    @assert (new_charges.n_charges == framework.charges.n_charges * prod(repfactors))
    @assert (new_atoms.n_atoms == framework.atoms.n_atoms * prod(repfactors))
    return Framework(framework.name, new_box, new_atoms, new_charges, deepcopy(framework.symmetry), framework.space_group, framework.is_p1)
end

# doc string in Misc.jl
function write_xyz(framework::Framework, filename::AbstractString;
                      comment::AbstractString="", center::Bool=false)
    atoms = framework.atoms.species
    x = zeros(Float64, 3, framework.atoms.n_atoms)
    for i = 1:framework.atoms.n_atoms
        x[:, i] = framework.box.f_to_c * framework.atoms.xf[:, i]
    end
    if center
        center_of_box = framework.box.f_to_c * [0.5, 0.5, 0.5]
        for i = 1:framework.atoms.n_atoms
            x[:, i] -= center_of_box
        end
    end

    write_xyz(atoms, x, filename, comment=comment)
end
write_xyz(framework::Framework; comment::AbstractString="", center::Bool=false) = write_xyz(
    framework,
    replace(replace(framework.name, ".cif" => ""), ".cssr" => "") * ".xyz",
    comment=comment, center=center)

"""
    is_overlap = atom_overlap(framework; overlap_tol=0.1, verbose=false)

Return true iff any two `Atoms` in the crystal overlap by calculating the distance
between every pair of atoms and ensuring distance is greater than
`overlap_tol`. If verbose, print the pair of atoms which are culprits.

# Arguments
- `framework::Framework`: The framework containing the crystal structure information
- `overlap_tol::Float64`: The minimum distance between two atoms without them overlapping
- `verbose:Bool`: If true, will print out extra information as it's running

# Returns
- `overlap::Bool`: A Boolean telling us if any two atoms in the framework are overlapping
"""
function atom_overlap(framework::Framework; overlap_tol::Float64=0.1, verbose::Bool=true)
    overlap = false
    for i = 1:framework.atoms.n_atoms
        for j = 1:framework.atoms.n_atoms
            if j >= i
                continue
            end
            if _overlap(framework.atoms.xf[:, i], framework.atoms.xf[:, j],
                        framework.box, overlap_tol)
                overlap = true
                if verbose
                    @warn @sprintf("Atoms %d and %d in %s are less than %d Å apart.", i, j,
                        framework.name, overlap_tol)
                end
            end
        end
    end
    return overlap
end

function charge_overlap(framework::Framework; overlap_tol::Float64=0.1, verbose::Bool=true)
    overlap = false
    for i = 1:framework.charges.n_charges
        for j = 1:framework.charges.n_charges
            if j >= i
                continue
            end
            if _overlap(framework.charges.xf[:, i], framework.charges.xf[:, j],
                        framework.box, overlap_tol)
                overlap = true
                if verbose
                    @warn @sprintf("Charges %d and %d in %s are less than %d Å apart.", i, j,
                        framework.name, overlap_tol)
                end
            end
        end
    end
    return overlap
end

# determine if two atoms overlap, returns the number of Atoms that
#   do overlap, and can then use that number to determine if they overlap or are repeats
function _overlap(xf_1::Array{Float64, 1}, xf_2::Array{Float64, 1},
                  box::Box, overlap_tol::Float64)
    dxf = mod.(xf_1, 1.0) .- mod.(xf_2, 1.0)
    nearest_image!(dxf)
    dxc = box.f_to_c * dxf
    return norm(dxc) < overlap_tol
end

function _overlap(xf::Union{Charges, Atoms}, box::Box, overlap_tol::Float64)
    return _overlap(xf, xf, box, overlap_tol)
end

#TODO write tests for this! one with diff elements
"""
    new_framework = remove_overlapping_atoms_and_charges(framework, overlap_tol=0.1, verbose=true)

Takes in a framework and returns a new framework with where overlapping atoms and overlapping
charges were removed. i.e. if there is an overlapping pair, one in the pair is removed.
For any atoms or charges to be removed, the species and charge, respectively,
must be identical.

# Arguments
- `framework::Framework`: The framework containing the crystal structure information
- `atom_overlap_tol::Float64`: The minimum distance between two atoms that is tolerated
- `charge_overlap_tol::Float64`: The minimum distance between two charges that is tolerated

# Returns
- `new_framework::Framework`: A new framework where identical atoms have been removed.
"""
function remove_overlapping_atoms_and_charges(framework::Framework;
    atom_overlap_tol::Float64=0.1, charge_overlap_tol::Float64=0.1, verbose::Bool=true)

    atoms_to_keep = trues(framework.atoms.n_atoms)
    charges_to_keep = trues(framework.charges.n_charges)

    for i = 1:framework.atoms.n_atoms
        for j =  1:framework.atoms.n_atoms
            if j >= i
                continue
            end
            if _overlap(framework.atoms.xf[:, i], framework.atoms.xf[:, j],
                        framework.box, atom_overlap_tol)
                if framework.atoms.species[i] != framework.atoms.species[j]
                    error(@sprintf("Atom %d, %s and atom %d, %s overlap but are not the
                    same element so we will not automatically remove one in the pair.\n",
                    i, framework.atoms.species[i], j, framework.atoms.species[j]))
                else
                    atoms_to_keep[i] = false
                end
            end
        end
    end
    if verbose
        println("# atoms removed: ", sum(.! atoms_to_keep))
    end

    for i = 1:framework.charges.n_charges
        for j = 1:framework.charges.n_charges
            if j >= i
                continue
            end
            if _overlap(framework.charges.xf[:, i], framework.charges.xf[:, j],
                        framework.box, charge_overlap_tol)
                if ! isapprox(framework.charges.q[i], framework.charges.q[j])
                    error(@sprintf("charge %d of %f and charge %d of %f overlap but are
                    not the same charge so we will not automatically remove one in the pair.\n",
                    i, framework.charges.q[j], j, framework.charges.q[j]))
                else
                    charges_to_keep[i] = false
                end
            end
        end
    end
    if verbose
        println("# charges removed: ", sum(.! charges_to_keep))
    end

    atom_coords_to_keep = Array{Float64, 2}(undef, 3, 0)
    for i = 1:length(atoms_to_keep)
        if atoms_to_keep[i]
            atom_coords_to_keep = [atom_coords_to_keep framework.atoms.xf[:, i]]
        end
    end
    charge_coords_to_keep = Array{Float64, 2}(undef, 3, 0)
    for i = 1:length(charges_to_keep)
        if charges_to_keep[i]
            charge_coords_to_keep = [charge_coords_to_keep framework.charges.xf[:, i]]
        end
    end

    atoms = Atoms(framework.atoms.species[atoms_to_keep], atom_coords_to_keep)
    charges = Charges(framework.charges.q[charges_to_keep], charge_coords_to_keep)

    new_framework = Framework(framework.name, framework.box, atoms, charges, deepcopy(framework.symmetry), framework.space_group, framework.is_p1)

    @assert (! atom_overlap(new_framework, overlap_tol=atom_overlap_tol))
    @assert (! charge_overlap(new_framework, overlap_tol=charge_overlap_tol))

    return new_framework
end

total_charge(framework::Framework) = (framework.charges.n_charges == 0) ? 0.0 : sum(framework.charges.q)

"""
    charge_neutral_flag = charge_neutral(framework, net_charge_tol) # true or false

Determine if the absolute value of the net charge in `framework` is less than `net_charge_tol`.
"""
function charge_neutral(framework::Framework, net_charge_tol::Float64)
    q = total_charge(framework)
    return abs(q) < net_charge_tol
end

"""
    charged_flag = charged(framework, verbose=false) # true or false

Determine if a framework has point charges
"""
function charged(framework::Framework; verbose::Bool=false)
    charged_flag = framework.charges.n_charges > 0
    if verbose
        @printf("\tFramework atoms of %s have charges? %s\n", framework.name, charged_flag)
    end
    return charged_flag
end

"""
    strip_numbers_from_atom_labels!(framework)

Strip numbers from labels for `framework.atoms`.
Precisely, for `atom` in `framework.atoms`, find the first number that appears in `atom`.
Remove this number and all following characters from `atom`.
e.g. C12 --> C
	 Ba12A_3 --> Ba

# Arguments
- `framework::Framework`: The framework containing the crystal structure information
"""
function strip_numbers_from_atom_labels!(framework::Framework)
    for i = 1:framework.atoms.n_atoms
        # atom species in string format
		species = string(framework.atoms.species[i])
		for j = 1:length(species)
			if ! isletter(species[j])
                framework.atoms.species[i] = Symbol(species[1:j-1])
				break
			end
		end
	end
    return
end

write_vtk(framework::Framework) = write_vtk(framework.box, split(framework.name, ".")[1])

"""
    formula = chemical_formula(framework, verbose=false)

Find the irreducible chemical formula of a crystal structure.

# Arguments
- `framework::Framework`: The framework containing the crystal structure information
- `verbose::Bool`: If `true`, will print the chemical formula as well

# Returns
- `formula::Dict{Symbol, Int}`: A dictionary with the irreducible chemical formula of a crystal structure
"""
function chemical_formula(framework::Framework; verbose::Bool=false)
    unique_atoms = unique(framework.atoms.species)
    # use dictionary to count atom types
    atom_counts = Dict{Symbol, Int}([a => 0 for a in unique_atoms])
    for i = 1:framework.atoms.n_atoms
        atom_counts[framework.atoms.species[i]] += 1
    end

    # get greatest common divisor
    gcd_ = gcd([k for k in values(atom_counts)])

    # turn into irreducible chemical formula
    for atom in keys(atom_counts)
        atom_counts[atom] = atom_counts[atom] / gcd_
    end

    # print result
    if verbose
        @printf("Chemical formula of %s:\n\t", framework.name)
        for (atom, formula_unit) in atom_counts
			@printf("%s_%d", string(atom), formula_unit)
        end
        @printf("\n")
    end

    return atom_counts
end

"""

    mass_of_framework = molecular_weight(framework)

Calculates the molecular weight of a unit cell of the framework in amu using information stored in `data/atomicmasses.csv`.

# Arguments
- `framework::Framework`: The framework containing the crystal structure information

# Returns
- `mass_of_framework::Float64`: The molecular weight of a unit cell of the framework in amu
"""
function molecular_weight(framework::Framework)
    atomic_masses = read_atomic_masses()

    mass = 0.0
	for i = 1:framework.atoms.n_atoms
        mass += atomic_masses[framework.atoms.species[i]]
    end

    return mass # amu
end

"""
    ρ = crystal_density(framework) # kg/m²

Compute the crystal density of a framework. Pulls atomic masses from [`read_atomic_masses`](@ref).

# Arguments
- `framework::Framework`: The framework containing the crystal structure information

# Returns
- `ρ::Float64`: The crystal density of a framework in kg/m³
"""
function crystal_density(framework::Framework)
    mw = molecular_weight(framework)
    return mw / framework.box.Ω * 1660.53892  # --> kg/m3
end

"""
    simulation_ready_framework = apply_symmetry_rules(non_p1_framework)

Convert a framework to P1 symmetry based on internal symmetry rules. This will
return the new framework.

# Arguments
- `f::Framework`: The framework to be converted to P1 symmetry
- `check_charge_neutrality::Bool`: check for charge neutrality
- `net_charge_tol::Float64`: when checking for charge neutrality, throw an error if the absolute value of the net charge is larger than this value.
- `check_atom_and_charge_overlap::Bool`: throw an error if overlapping atoms are detected.
- `remove_overlap::Bool`: remove identical atoms automatically. Identical atoms are the same element atoms which overlap.

# Returns
- `P1_framework::Framework`: The framework after it has been converted to P1
    symmetry. The new symmetry rules will be the P1 symemtry rules
"""
function apply_symmetry_rules(framework::Framework; check_charge_neutrality::Bool=true,
                              net_charge_tol::Float64=0.001, check_atom_and_charge_overlap::Bool=true,
                              remove_overlap::Bool=false)
    new_atom_xfs = Array{Float64, 2}(undef, 3, 0)
    new_charge_xfs = Array{Float64, 2}(undef, 3, 0)
    new_atom_species = Array{Symbol, 1}(undef, 0)
    new_charge_qs = Array{Float64, 1}(undef, 0)

    # for each symmetry rule
    for i in 1:size(framework.symmetry, 2)
        # loop over all atoms in lower level symemtry
        for j in 1:size(framework.atoms.xf, 2)
            # apply current symmetry rule to current atom for x, y, and z coordinates
            new_atom_xfs = [new_atom_xfs [Base.invokelatest.(
                        eval(Meta.parse("(x, y, z) -> " * framework.symmetry[k, i])),
                        framework.atoms.xf[:, j]...) for k in 1:3]]
        end
        # loop over all charges in lower level symmetry
        for j in 1:size(framework.charges.xf, 2)
            # apply current symmetry rule to current atom for x, y, and z coordinates
            new_charge_xfs = [new_charge_xfs [Base.invokelatest.(
                        eval(Meta.parse("(x, y, z) -> " * framework.symmetry[k, i])),
                        framework.charges.xf[:, j]...) for k in 1:3]]
        end
        # repeat charge_qs and atom_species for every symmetry applied
        new_atom_species = [new_atom_species; framework.atoms.species]
        new_charge_qs = [new_charge_qs; framework.charges.q]
    end

    new_symmetry_rules = [Array{AbstractString, 2}(undef, 3, 0) ["x", "y", "z"]]

    new_framework = Framework(framework.name, framework.box,
        Atoms(new_atom_species, new_atom_xfs),
        Charges(new_charge_qs, new_charge_xfs), new_symmetry_rules, "P1", true)

    if check_charge_neutrality
        if ! charge_neutral(new_framework, net_charge_tol)
            error(@sprintf("Framework %s is not charge neutral; net charge is %f e. Ignore
            this error message by passing check_charge_neutrality=false or increasing the
            net charge tolerance `net_charge_tol`\n",
                            new_framework.name, total_charge(new_framework)))
        end
    end

    if remove_overlap
        return remove_overlapping_atoms_and_charges(new_framework)
    end

    if check_atom_and_charge_overlap
        if atom_overlap(new_framework) | charge_overlap(new_framework)
            error(@sprintf("At least one pair of atoms/charges overlap in %s.
            Consider passing `remove_overlap=true`\n", new_framework.name))
        end
    end

    return new_framework
end

"""
    symmetry_equal = is_symmetry_equal(framework1.symmetry, framework2.symmetry)

Returns true if both symmetry rules can create the same set from the same set
of coordinates. Returns false if they don't contain the same number of rules or
if they create different sets of points.

# Arguments
- `sym1::Array{AbstractString, 2}`: Array of strings that represent
    symmetry operations
- `sym2::Array{AbstractString, 2}`: Array of strings that represent
    symmetry operations

# Returns
- `is_equal::Bool`: True if they are the same set of symmetry rules
    False if they are different
"""
function is_symmetry_equal(sym1::Array{AbstractString, 2}, sym2::Array{AbstractString, 2})
    # need same number of symmetry operations
    if size(sym1, 2) != size(sym2, 2)
        return false
    end
    # define a test array that operations will be performed on
    test_array = [0.0 0.25 0.0  0.0  0.0  0.25 0.25 0.25;
                  0.0 0.0  0.25 0.0  0.25 0.0  0.25 0.25;
                  0.0 0.0  0.0  0.25 0.25 0.25 0.25 0.25]
    # set up both arrays for storing replicated coords
    sym1_applied_to_test = Array{Float64, 2}(undef, 3, 0)
    sym2_applied_to_test = Array{Float64, 2}(undef, 3, 0)

    # loop over all positions in the test_array
    for i in 1:size(test_array, 2)
        # loop over f1 symmetry rules
        for j in 1:size(sym1, 2)
            sym1_applied_to_test = [sym1_applied_to_test [Base.invokelatest.(
                eval(Meta.parse("(x, y, z) -> " * sym1[k, j])), test_array[:, i]...) for k in 1:3]]
        end
        # loop over f2 symmetry rules
        for j in 1:size(sym2, 2)
            sym2_applied_to_test = [sym2_applied_to_test [Base.invokelatest.(
                eval(Meta.parse("(x, y, z) -> " * sym2[k, j])), test_array[:, i]...) for k in 1:3]]
        end
    end

    # convert to sets for using issetequal, symmetry rules might be in a a different order
    sym1_set = Set([sym1_applied_to_test[:, i] for i in 1:size(sym1_applied_to_test, 2)])
    sym2_set = Set([sym2_applied_to_test[:, i] for i in 1:size(sym2_applied_to_test, 2)])

    # return if the sets of coords are equal
    return issetequal(sym1_set, sym2_set)
end

"""
    write_cif(framework, filename)

Write a `framework::Framework` to a .cif file with `filename::AbstractString`. If `filename` does
not include the .cif extension, it will automatically be added.
"""
function write_cif(framework::Framework, filename::AbstractString; fractional::Bool=true)
    if charged(framework) && (framework.atoms.n_atoms != framework.charges.n_charges)
        error("write_cif assumes equal numbers of Charges and Atoms (or zero charges)")
    end
    # append ".cif" to filename if it doesn't already have the extension
    if ! occursin(".cif", filename)
        filename *= ".cif"
    end
    cif_file = open(filename, "w")
    # first line should be data_xtalname_PM
    if framework.name == ""
        @printf(cif_file, "data_PM\n")
    else
        # don't include file extension!
        @printf(cif_file, "data_%s_PM\n", split(framework.name, ".")[1])
    end

    @printf(cif_file, "_symmetry_space_group_name_H-M   '%s'\n", framework.space_group)

    @printf(cif_file, "_cell_length_a %f\n", framework.box.a)
    @printf(cif_file, "_cell_length_b %f\n", framework.box.b)
    @printf(cif_file, "_cell_length_c %f\n", framework.box.c)

    @printf(cif_file, "_cell_angle_alpha %f\n", framework.box.α * 180.0 / pi)
    @printf(cif_file, "_cell_angle_beta %f\n", framework.box.β * 180.0 / pi)
    @printf(cif_file, "_cell_angle_gamma %f\n", framework.box.γ * 180.0 / pi)

    @printf(cif_file, "_symmetry_Int_Tables_number 1\n\n")
    @printf(cif_file, "loop_\n_symmetry_equiv_pos_as_xyz\n")
    for i in 1:size(framework.symmetry, 2)
        @printf(cif_file, "'%s,%s,%s'\n", framework.symmetry[:, i]...)
    end
    @printf(cif_file, "\n")

    @printf(cif_file, "loop_\n_atom_site_label\n")
    if fractional
        @printf(cif_file, "_atom_site_fract_x\n_atom_site_fract_y\n_atom_site_fract_z\n")
    else
        @printf(cif_file, "_atom_site_Cartn_x\n_atom_site_Cartn_y\n_atom_site_Cartn_z\n")
    end
    @printf(cif_file, "_atom_site_charge\n")

    for i = 1:framework.atoms.n_atoms
        q = 0.0
        if charged(framework)
            q = framework.charges.q[i]
            if ! isapprox(framework.charges.xf[:, i], framework.atoms.xf[:, i])
                error("write_cif assumes charges correspond to LJspheres")
            end
        end
        if fractional
            @printf(cif_file, "%s %f %f %f %f\n", framework.atoms.species[i],
                    framework.atoms.xf[:, i]..., q)
        else
            
            @printf(cif_file, "%s %f %f %f %f\n", framework.atoms.species[i],
                    (framework.box.f_to_c * framework.atoms.xf[:, i])..., q)
        end
     end
     close(cif_file)
end

"""
    new_framework = assign_charges(framework, charges, net_charge_tol=1e-5)

Assign charges to the atoms present in the framework.
Pass a dictionary of charges that place charges according to the species
of the atoms or pass an array of charges to assign to each atom, with the order of the
array consistent with the order of `framework.atoms`.

If the framework already has charges, the charges are removed and new charges are added
accordingly so that `framework.atoms.n_atoms == framework.charges.n_charges`.

# Examples
```
charges = Dict(:Ca => 2.0, :C => 1.0, :H => -1.0)
new_framework = assign_charges(framework, charges)
```

```
charges = [4.0, 2.0, -6.0] # framework.atoms is length 3
new_framework = assign_charges(framework, charges)
```

# Arguments
- `framework::Framework`: the framework to which we should add charges (not modified in
this function)
- `charges::Union{Dict{Symbol, Float64}, Array{Float64, 1}}`: a dictionary that returns the
charge assigned to the species of atom or an array of charges to assign, with order
consistent with the order in `framework.atoms` (units: electrons).
- `net_charge_tol::Float64`: the net charge tolerated when asserting charge neutrality of
the resulting framework

# Returns
- `new_framework::Framework`: a new framework identical to the one passed except charges
are assigned.
"""
function assign_charges(framework::Framework, charges::Union{Dict{Symbol, Float64}, Array{Float64, 1}},
    net_charge_tol::Float64=1e-5)
    # if charges are already present, may make little sense to assign charges to atoms again
    if framework.charges.n_charges != 0
        @warn @sprintf("Charges are already present in %s. Removing the current charges on the
        framework and adding new ones...\n", framework.name)
    end

    # build the array of point charges according to atom species
    charge_vals = Array{Float64, 1}()
    charge_coords = Array{Float64, 2}(undef, 3, 0)
    for i = 1:framework.atoms.n_atoms
        if isa(charges, Dict{Symbol, Float64})
            if ! (framework.atoms.species[i] in keys(charges))
                error(@sprintf("Atom %s is not present in the charge dictionary passed to
                `assign_charges` for %s\n", atom.species, framework.name))
            end
            push!(charge_vals, charges[framework.atoms.species[i]])
            charge_coords = [charge_coords framework.atoms.xf[:, i]]
        else
            if length(charges) != framework.atoms.n_atoms
                error(@sprintf("Length of `charges` array passed to `assign_charges` is not
                equal to the number of atoms in %s = %d\n", framework.name,
                framework.atoms.n_atoms))
            end
            push!(charge_vals, charges[i])
            charge_coords = [charge_coords framework.atoms.xf[:, i]]
        end
    end

    charges = Charges(charge_vals, charge_coords)

    # construct new framework
    new_framework = Framework(framework.name, framework.box, framework.atoms, charges, deepcopy(framework.symmetry), framework.space_group, framework.is_p1)

    # check for charge neutrality
    if abs(total_charge(new_framework)) > net_charge_tol
        error(@sprintf("Net charge of framework %s = %f > net charge tolerance %f. If
        charge neutrality is not a problem, pass `net_charge_tol=Inf`\n", framework.name,
        total_charge(new_framework), net_charge_tol))
    end

    return new_framework
end

function Base.show(io::IO, framework::Framework)
    println(io, "Name: ", framework.name)
    println(io, framework.box)
	@printf(io, "Number of atoms = %d\n", framework.atoms.n_atoms)
	@printf(io, "Number of charges = %d\n", framework.charges.n_charges)
    println(io, "Chemical formula: ", chemical_formula(framework))
    @printf(io, "Space Group: %s\n", framework.space_group)
    @printf(io, "Symmetry Operations:\n")
    for i in 1:size(framework.symmetry, 2)
        @printf(io, "\t'%s, %s, %s'\n", framework.symmetry[:, i]...)
    end
end

# TODO add something comparing symmetry rules
function Base.isapprox(f1::Framework, f2::Framework; checknames::Bool=false)
    names_flag = f1.name == f2.name
    if checknames && (! names_flag)
        return false
    end
    box_flag = isapprox(f1.box, f2.box)
    if f1.charges.n_charges != f2.charges.n_charges
        return false
    end
    if f1.atoms.n_atoms != f2.atoms.n_atoms
        return false
    end
    charges_flag = isapprox(f1.charges, f2.charges)
    atoms_flag = isapprox(f1.atoms, f2.atoms)
    symmetry_flag = is_symmetry_equal(f1.symmetry, f2.symmetry)
    return box_flag && charges_flag && atoms_flag && symmetry_flag
end

function Base.:+(frameworks::Framework...; check_overlap=true)
    new_framework = Framework("", frameworks[1].box,
                  Atoms(Array{Symbol, 1}(undef, 0), Array{Float64, 2}(undef, 3, 0)),
                  Charges(Array{Float64, 1}(undef, 0), Array{Float64, 2}(undef, 3, 0)),
                  frameworks[1].symmetry, frameworks[1].space_group, frameworks[1].is_p1)
    for f in frameworks
        @assert isapprox(new_framework.box, f.box) @sprintf("Framework %s has a different box\n", f.name)
        @assert is_symmetry_equal(new_framework.symmetry, f.symmetry) @sprintf("Framework %s has different symmetry rules\n", f.name)
        @assert new_framework.space_group == f.space_group

        new_atoms = new_framework.atoms + f.atoms
        new_charges = new_framework.charges + f.charges

        new_framework = Framework(new_framework.name * "_" * f.name, new_framework.box,
                                 new_atoms, new_charges, new_framework.symmetry,
                                 new_framework.space_group, new_framework.is_p1)
    end
    if check_overlap
        if atom_overlap(new_framework)
            @warn "This new framework has overlapping atoms, use:\n`remove_overlapping_atoms_and_charges(framework)`\nto remove them"
        end

        if charge_overlap(new_framework)
            @warn "This new framework has overlapping charges, use:\n`remove_overlapping_atoms_and_charges(framework)`\nto remove them"
        end
    end

    return new_framework
end
