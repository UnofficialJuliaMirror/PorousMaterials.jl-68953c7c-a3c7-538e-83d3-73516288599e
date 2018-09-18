module Grid_Test

using PorousMaterials
using OffsetArrays
using LinearAlgebra
using Test
using JLD2
using Statistics
using Random

@testset "Grid Tests" begin
    # test read and write
    grid = Grid(Box(0.7, 0.8, 0.9, 1.5, 1.6, 1.7), (3, 3, 3), rand(Float64, (3, 3, 3)),
        :kJ_mol, [1., 2., 3.])
    write_cube(grid, "test_grid.cube")
    grid2 = read_cube("test_grid.cube")
    @test isapprox(grid, grid2)
    
    # nearest neighbor ID checker
    n_pts = (10, 20, 30)
    @test PorousMaterials._arg_nearest_neighbor(n_pts, [0.001, 0.001, 0.001]) == [1, 1, 1]
    @test PorousMaterials._arg_nearest_neighbor(n_pts, [0.999, 0.999, 0.999]) == [10, 20, 30]
    idx = [0, 21, 31]
    PorousMaterials._apply_pbc_to_index!(idx, n_pts)
    @test idx == [10, 1, 1]
    n_pts = (3, 3, 3) # so grid is [0, 0.5, 1.0]
    @test PorousMaterials._arg_nearest_neighbor(n_pts, [0.001, 0.001, 0.001]) == [1, 1, 1]
    @test PorousMaterials._arg_nearest_neighbor(n_pts, [0.999, 0.999, 0.999]) == [3, 3, 3]
    @test PorousMaterials._arg_nearest_neighbor(n_pts, [0.001, 0.001, 0.24]) == [1, 1, 1]
    @test PorousMaterials._arg_nearest_neighbor(n_pts, [0.001, 0.001, 0.26]) == [1, 1, 2]
    @test PorousMaterials._arg_nearest_neighbor(n_pts, [0.74, 0.001, 0.26]) == [2, 1, 2]
    @test PorousMaterials._arg_nearest_neighbor(n_pts, [0.76, 0.001, 0.26]) == [3, 1, 2]
    
    # accessibility grids
    for zeolite in ["LTA", "SOD"]
        framework = Framework(zeolite * ".cif")
        write_xyz(framework)
        molecule = Molecule("CH4")
        forcefield = LJForceField("UFF.csv")
        grid = energy_grid(framework, molecule, forcefield, n_pts=(10, 10, 10))

        # endpoints included, ensure periodic since endpoints of grid pts included
        #   first cut out huge values. 1e46 == 1.00001e46
        grid.data[grid.data .> 1000.0] .= 0.0
        @test isapprox(grid.data[1, :, :], grid.data[end, :, :], atol=1e-7)
        @test isapprox(grid.data[:, 1, :], grid.data[:, end, :], atol=1e-7)
        @test isapprox(grid.data[:, :, 1], grid.data[:, :, end], atol=1e-7)

        accessibility_grid, some_pockets_were_blocked = compute_accessibility_grid(framework, 
            molecule, forcefield, n_pts=(20, 20, 20), energy_tol=0.0, verbose=false, 
            write_b4_after_grids=true)
        @test some_pockets_were_blocked

        @test isapprox(framework.box, accessibility_grid.box)

        if zeolite == "SOD"
            @test all(.! accessibility_grid.data)
        end

        # test accessibility by inserting random particles and writing to .xyz only if not accessible
        nb_insertions = 100000
        x = zeros(3, 0)
        for i = 1:nb_insertions
            xf = rand(3)
            if accessible(accessibility_grid, xf)
                x = hcat(x, framework.box.f_to_c * xf)
                @assert accessible(accessibility_grid, xf, (1, 1, 1))
            else
                @assert ! accessible(accessibility_grid, xf, (1, 1, 1))
            end
        end
        if zeolite == "SOD"
            # shldn't be any accessible insertions
            @test length(x) == 0
        else
            xyzfilename = zeolite * "accessible_inertions.xyz"
            write_xyz([:CH4 for i = 1:size(x)[2]], x, xyzfilename)
            println("See ", xyzfilename)
        end
    end

    # test accessibility interpolator when there are replications
    framework = Framework("LTA.cif")
    molecule = Molecule("CH4")
    forcefield = LJForceField("UFF.csv")
    accessibility_grid, some_pockets_were_blocked = compute_accessibility_grid(framework, 
        molecule, forcefield, n_pts=(20, 20, 20), energy_tol=0.0, verbose=false, 
        write_b4_after_grids=true)
    # replicate framework and build accessibility grid that includes the other accessibility grid in a corner
    repfactors = (2, 3, 1)
    framework = replicate(framework, repfactors)
    rep_accessibility_grid, rep_some_pockets_were_blocked = compute_accessibility_grid(framework, 
        molecule, forcefield, n_pts=(20 * 2 - 1, 20 * 3 - 2, 20), energy_tol=0.0, verbose=false, 
        write_b4_after_grids=true)
    @test all(accessibility_grid.data .== rep_accessibility_grid.data[1:20, 1:20, 1:20])
    @test rep_some_pockets_were_blocked
    same_accessibility_repfactors = true
    for i = 1:10000
        xf = rand(3) # in (2, 3, 1) box
        if ! (accessible(rep_accessibility_grid, xf) == accessible(accessibility_grid, xf, repfactors))
            same_accessibility_repfactors = false
        end
    end
    @test same_accessibility_repfactors
end
end
