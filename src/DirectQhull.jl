module DirectQhull

# MIT License
# 
# Copyright (c) 2022 Juha Tapio Heiskala
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# functions "qh_get_extremes_2d" and "qh_get_simplex_facet_arrays" defined later
# licensed under BSD license from Scipy

import Qhull_jll

import Base.getproperty
import Base.iterate
import Base.getindex
import Base.length

# define Qhull types

const QHboolT = Cuint
const QHrealT = Cdouble
const QHcoordT = QHrealT
const QHpointT = QHcoordT
const QHintT = Cint 
const QHprintT = Cint
const QHcharT = Cchar
const QHuintT = Cuint
const QHulongT = Culong
const QHcenterT = Cint
const QHdoubleT = Cdouble
const QHvoidT = Cvoid
const QHfileT = Cvoid

export ConvexHull, Voronoi, Delaunay, HalfspaceIntersection

# holds pointer to qhT structure
mutable struct qhT end


function Base.getproperty(qh_ptr::Ptr{qhT}, fld::Symbol)
    if fld === :input_dim
        return qh_get_input_dim(qh_ptr)
    elseif fld === :hull_dim
        return qh_get_hull_dim(qh_ptr)
    elseif fld === :num_facets
        return qh_get_num_facets(qh_ptr)
    elseif fld === :num_points
        return qh_get_num_points(qh_ptr)
    elseif fld === :facet_list
        return qh_get_facet_list(qh_ptr, Val(qh_ptr.hull_dim))
    elseif fld === :vertex_list
        return qh_get_vertex_list(qh_ptr, Val(qh_ptr.hull_dim))
    elseif fld === :center_size
        return qh_get_center_size(qh_ptr)
    elseif fld === :UPPERdelaunay
        return qh_get_UPPERdelaunay(qh_ptr)
    elseif fld === :SCALElast
        return qh_get_SCALElast(qh_ptr)
    elseif fld === :last_low
        return qh_get_last_low(qh_ptr)
    elseif fld === :last_high
        return qh_get_last_high(qh_ptr)
    elseif fld === :last_newhigh
        return qh_get_last_newhigh(qh_ptr)
    elseif fld === :first_point_ptr
        return qh_get_first_point_ptr(qh_ptr)
    else
        throw(ErrorException("Unknown qh field"))
    end
end

# defines clockwise or counterclockwise orientation e.g. 2d-convex hull vertex ordering
const qh_ORIENTclock = 0
const qh_RIDGEall = 0

const qh_lib = Qhull_jll.get_libqhull_r_path()

function qh_alloc_qh(err_file::Ptr{Cvoid}=C_NULL)
    qh_ptr = ccall((:qh_alloc_qh, qh_lib), Ptr{qhT}, (Ptr{Cvoid},), err_file)    
    (qh_ptr != C_NULL) ? qh_ptr : throw(ErrorException("qhT initialization failure."))
end

# This should always be true (tested for the QHsetT so that Union{Int, Pointers} as QHsetT element is valid) 
@assert(sizeof(Ptr{Cvoid}) == sizeof(Int))

abstract type QHsetelemT end

# this is not an exact representation of QHull's set type
# Qhull set is dynamically allocated so exact representation is not straighforward as Julia type.
# (would require NTuple type for elements with tuple length equal to number elements in the list)
# so the set elements are wrapped by Julia array
# QH set element type is defined as union of void pointer and integer
struct QHsetT{T<:Union{QHintT, Ptr{<:Union{QHsetelemT, NTuple, QHpointT}}}}
    maxsize::QHintT          # /* maximum number of elements (except NULL) */
    e::Array{T}              # /* array of pointers, tail is NULL */
                             # /* last slot (unless NULL) is actual size+1
                             # /* e[maxsize]==NULL or e[e[maxsize]-1]==NULL */
                             # /* this may generate a warning since e[] contains  maxsize elements */
    function QHsetT{T}(ptr::Ptr{QHsetT{T}}) where T<:Ptr{<:Union{QHsetelemT, NTuple, QHpointT}}
        max_size = unsafe_load(Ptr{QHintT}(ptr))

        # with passing C_NULL as qh_ptr below the call will crash, if the setsize is invalid
        # however, qhull would anyway exit in this case with internal error, though in a more gracious manner
        # (this removes the need to pass the qhT pointer to this constructor)
        set_size = qh_setsize(Ptr{qhT}(C_NULL), ptr)
        # assumed here QHsetT field e is offset Ptr-size from the maxsize field
        ptr_array = unsafe_wrap(Array, Ptr{T}(ptr+sizeof(Ptr)), set_size)
        new(max_size, ptr_array)
    end
end

function Base.getindex(set::QHsetT{T}, idx::Int) where T<:Union{QHintT, Ptr{<:QHsetelemT}}
    ptr = set.e[idx]
    unsafe_load(ptr)
end

function Base.length(set::QHsetT{T}) where T<:Union{QHintT, Ptr{<:QHsetelemT}}
    return length(set.e)
end

# QH set as providing raw pointers
struct QHsetPtrT{T<:Union{QHintT, Ptr{<:Union{QHsetelemT, NTuple, QHpointT}}}}
    maxsize::QHintT          # /* maximum number of elements (except NULL) */
    e::Array{T}              # /* array of pointers, tail is NULL */
                             # /* last slot (unless NULL) is actual size+1
                             # /* e[maxsize]==NULL or e[e[maxsize]-1]==NULL */
                             # /* this may generate a warning since e[] contains  maxsize elements */
    function QHsetPtrT{T}(ptr::Ptr{QHsetPtrT{T}}) where T<:Ptr{<:Union{QHsetelemT, NTuple, QHpointT}}
        max_size = unsafe_load(Ptr{QHintT}(ptr))
        # with passing C_NULL as qh_ptr below the call will crash, if the setsize is invalid
        # however, qhull would anyway exit in this case with internal error, though in a more gracious manner
        # (this removes the need to pass the qhT pointer to this constructor)
        set_size = qh_setsize(Ptr{qhT}(C_NULL), ptr)
        # assumed here QHsetT field e is offset Ptr-size from the maxsize field
        ptr_array = unsafe_wrap(Array, Ptr{T}(ptr+sizeof(Ptr)), set_size)
        new(max_size, ptr_array)
    end
end

function Base.getindex(set::QHsetPtrT{T}, idx::Int) where T<:Union{QHintT, Ptr{<:QHsetelemT}}
    set.e[idx]
end

Base.length(set::QHsetPtrT{T}) where T<:Union{QHintT, Ptr{<:QHsetelemT}} = length(set.e)


# Qhull vertex type
# Comments are from original qhull code.
mutable struct QHvertexT{HD} <: QHsetelemT
    next::Ptr{QHvertexT{HD}}                # /* next vertex in vertex_list or vertex_tail */
    previous::Ptr{QHvertexT{HD}}            # /* previous vertex in vertex_list or NULL, for C++ interface */
    point::Ptr{NTuple{HD, QHpointT}}        # /* hull_dim coordinates (coordT) */
    neighbors::Ptr{QHsetT{<:QHsetelemT}}    # /* neighboring facets of vertex, qh_vertexneighbors()
                                            # initialized in io_r.c or after first merge
                              # qh_update_vertices for qh_addpoint or qh_triangulate
                              # updated by merges
                              # qh_order_vertexneighbors by 2-d (orientation) 3-d (adjacency), n-d (f.visitid,id) */
    id::QHuintT               # /* unique identifier, 1..qh.vertex_id,  0 for sentinel, printed as 'r%d' */
    visitid::QHuintT          # /* for use with qh.vertex_visit, size must match */
    flags::QHcharT
    # seen:1;      /* used to perform operations only once */
    #flagT    seen2:1;     /* another seen flag */
    #flagT    deleted:1;   /* vertex will be deleted via qh.del_vertices */
    #flagT    delridge:1;  /* vertex belonged to a deleted ridge, cleared by qh_reducevertices */
    #flagT    newfacet:1;  /* true if vertex is in a new facet
    #                       vertex is on qh.newvertex_list and it has a facet on qh.newfacet_list
    #                       or vertex is on qh.newvertex_list due to qh_newvertices while merging
    #                       cleared by qh_resetlists */
    #flagT    partitioned:1; /* true if deleted vertex has been partitioned */
end

# Qhull facet type
# Comments are from original qhull code.
mutable struct QHfacetT{HD} <: QHsetelemT
    furthestdist::QHcoordT  # distance to furthest point of outsideset
    maxoutside::QHcoordT    # max computed distance of point to facet
                            # Before QHULLfinished this is an approximation
                            # since maxdist not always set for qh_mergefacet
                            # Actual outer plane is +DISTround and
                            # computed outer plane is +2*DISTround.
                            # Initial maxoutside is qh.DISTround, otherwise distance tests need to account for DISTround */

    offset::QHcoordT        # exact offset of hyperplane from origin 
    normal::Ptr{NTuple{HD, QHcoordT}}   # normal of hyperplane, hull_dim coefficients 
                            # if f.tricoplanar, shared with a neighbor

    #union {                # in order of testing */
    area::QHrealT           # area of facet, only in io_r.c if  f.isarea */
    #facetT *replace    # replacement facet for qh.NEWfacets with f.visible
                            # NULL if qh_mergedegen_redundant, interior, or !NEWfacets */
                            # facetT *samecycle;   /* cycle of facets from the same visible/horizon intersection,
                            # if ->newfacet */
    # facetT *newcycle;    /*  in horizon facet, current samecycle of new facets */
    # facetT *trivisible;  /* visible facet for ->tricoplanar facets during qh_triangulate() */
    # facetT *triowner;    /* owner facet for ->tricoplanar, !isarea facets w/ ->keepcentrum */
    # }f;
    center::Ptr{QHcoordT}  # set according to qh.CENTERtype */
                           # qh_ASnone:    no center (not MERGING) */
                           # qh_AScentrum: centrum for testing convexity (qh_getcentrum) */
                           #               assumed qh_AScentrum while merging */
                           # qh_ASvoronoi: Voronoi center (qh_facetcenter) */
                           # after constructing the hull, it may be changed (qh_clearcenter) */
                           # if tricoplanar and !keepcentrum, shared with a neighbor */
    previous::Ptr{QHfacetT{HD}} # previous facet in the facet_list or NULL, for C++ interface */
    next::Ptr{QHfacetT{HD}}     # next facet in the facet_list or facet_tail */
    vertices::Ptr{QHsetT{Ptr{QHvertexT{HD}}}}   # vertices for this facet, inverse sorted by ID
                            # if simplicial, 1st vertex was apex/furthest
                            # qh_reduce_vertices removes extraneous vertices via qh_remove_extravertices
                            # if f.visible, vertices may be on qh.del_vertices */
    ridges::Ptr{QHsetT}     # explicit ridges for nonsimplicial facets or nonsimplicial neighbors.
                            # For simplicial facets, neighbors define the ridges
                            # qh_makeridges() converts simplicial facets by creating ridges prior to merging
                            # If qh.NEWtentative, new facets have horizon ridge, but not vice versa
                            # if f.visible && qh.NEWfacets, ridges is empty */
    neighbors::Ptr{QHsetT{Ptr{QHfacetT{HD}}}}  # neighbors of the facet.  Neighbors may be f.visible
                            # If simplicial, the kth neighbor is opposite the kth vertex and the
                            # first neighbor is the horizon facet for the first vertex.
                            # dupridges marked by qh_DUPLICATEridge (0x01) and qh_MERGEridge (0x02)
                            # if f.visible && qh.NEWfacets, neighbors is empty */
    outsideset::Ptr{QHsetT} # set of points outside this facet
                            # if non-empty, last point is furthest
                            # if NARROWhull, includes coplanars (less than qh.MINoutside) for partitioning*/
    coplanarset::Ptr{QHsetT{Ptr{NTuple{HD, QHpointT}}}} # set of points coplanar with this facet
                             # >= qh.min_vertex and <= facet->max_outside
                             # a point is assigned to the furthest facet
                             # if non-empty, last point is furthest away */
    visitid::QHuintT         # visit_id, for visiting all neighbors, all uses are independent */
    id::QHuintT              # unique identifier from qh.facet_id, 1..qh.facet_id, 0 is sentinel, printed as 'f%d' */
    flags::QHuintT

    # unsigned int nummerge:9; /* number of merges */
    # define qh_MAXnummerge 511 /* 2^9-1 */
    #                        /* 23 flags (at most 23 due to nummerge), printed by "flags:" in io_r.c */
    # flagT    tricoplanar:1; /* True if TRIangulate and simplicial and coplanar with a neighbor */
    #                      /*   all tricoplanars share the same apex */
    #                      /*   all tricoplanars share the same ->center, ->normal, ->offset, ->maxoutside */
    #                      /*     ->keepcentrum is true for the owner.  It has the ->coplanareset */
    #                      /*   if ->degenerate, does not span facet (one logical ridge) */
    #                      /*   during qh_triangulate, f.trivisible points to original facet */
    # flagT    newfacet:1;  /* True if facet on qh.newfacet_list (new/qh.first_newfacet or merged) */
    # flagT    visible:1;   /* True if visible facet (will be deleted) */
    # flagT    toporient:1; /* True if created with top orientation
    #                       after merging, use ridge orientation */
    # flagT    simplicial:1;/* True if simplicial facet, ->ridges may be implicit */
    # flagT    seen:1;      /* used to perform operations only once, like visitid */
    # flagT    seen2:1;     /* used to perform operations only once, like visitid */
    # flagT    flipped:1;   /* True if facet is flipped */
    # flagT    upperdelaunay:1; /* True if facet is upper envelope of Delaunay triangulation */
    # flagT    notfurthest:1; /* True if last point of outsideset is not furthest */
    #
    # /*-------- flags primarily for output ---------*/
    # flagT    good:1;      /* True if a facet marked good for output */
    # flagT    isarea:1;    /* True if facet->f.area is defined */

    # /*-------- flags for merging ------------------*/
    # flagT    dupridge:1;  /* True if facet has one or more dupridge in a new facet (qh_matchneighbor),
    #                         a dupridge has a subridge shared by more than one new facet */
    # flagT    mergeridge:1; /* True if facet or neighbor has a qh_MERGEridge (qh_mark_dupridges)
    #                        ->normal defined for mergeridge and mergeridge2 */
    # flagT    mergeridge2:1; /* True if neighbor has a qh_MERGEridge (qh_mark_dupridges) */
    # flagT    coplanarhorizon:1;  /* True if horizon facet is coplanar at last use */
    # flagT     mergehorizon:1; /* True if will merge into horizon (its first neighbor w/ f.coplanarhorizon). */
    # flagT     cycledone:1;/* True if mergecycle_all already done */
    # flagT    tested:1;    /* True if facet convexity has been tested (false after merge */
    # flagT    keepcentrum:1; /* True if keep old centrum after a merge, or marks owner for ->tricoplanar
    #                          Set by qh_updatetested if more than qh_MAXnewcentrum extra vertices
    #                          Set by qh_mergefacet if |maxdist| > qh.WIDEfacet */
    # flagT    newmerge:1;  /* True if facet is newly merged for reducevertices */
    # flagT    degenerate:1; /* True if facet is degenerate (degen_mergeset or ->tricoplanar) */
    # flagT    redundant:1;  /* True if facet is redundant (degen_mergeset)
    #                     Maybe merge degenerate and redundant to gain another flag */
end


# Iteration for facet list
function iterate(first_fct::QHfacetT{HD}) where HD
    return (first_fct, first_fct.next_ptr)    
end

function iterate(first_fct::QHfacetT{HD}, next_fct_ptr::Ptr{QHfacetT{HD}}) where HD
    next_fct = unsafe_load(next_fct_ptr)
    ## ID=0 is dummy facet that indicates end of the list
    if next_fct.id == QHuintT(0)
        return nothing
    else
        return (next_fct, next_fct.next_ptr)
    end
end

# Iteration for vertex list
function iterate(first_vtx::QHvertexT{HD}) where HD
    return (first_vtx, first_vtx.next_ptr)    
end

function iterate(first_vtx::QHvertexT{HD}, next_vtx_ptr::Ptr{QHvertexT{HD}}) where HD
    next_vtx = unsafe_load(next_vtx_ptr)
    ## ID=0 is dummy vertext that indicates end of the list
    if next_vtx.id == QHuintT(0)
        return nothing
    else
        return (next_vtx, next_vtx.next_ptr)
    end
end


# Iterate QHsetT with pointer types
function iterate(set::QHsetT{T}) where T<:Ptr{<:Union{QHsetelemT, NTuple, QHpointT}}

    if length(set.e) == 0
        return nothing
    else
        return (unsafe_load(set.e[1]), 2)
    end
end

function iterate(set::QHsetT{T}, idx::Int) where T<:Ptr{<:Union{QHsetelemT, NTuple, QHpointT}}
    if idx > length(set.e)
        return nothing
    else
        return (unsafe_load(set.e[idx]), idx+1)
    end
end

# Iterate QHsetT with pointer types
function iterate(set::QHsetPtrT{T}) where T<:Ptr{<:Union{QHsetelemT, NTuple, QHpointT}}

    if length(set.e) == 0
        return nothing
    else
        return (set.e[1], 2)
    end
end

function iterate(set::QHsetPtrT{T}, idx::Int) where T<:Ptr{<:Union{QHsetelemT, NTuple, QHpointT}}
    if idx > length(set.e)
        return nothing
    else
        return (set.e[idx], idx+1)
    end
end


# Build convex hull from a set points
struct ConvexHull
    qh_ptr::Ptr{qhT}
    points::Matrix{QHcoordT}
    vertices::Vector{QHuintT}
    simplices::Matrix{QHuintT}
    neighbors::Matrix{QHuintT}
    equations::Matrix{QHrealT}
    coplanar::Matrix{QHintT}
    good::Vector{QHboolT}
    area::QHrealT
    volume::QHrealT
    max_bound::Vector{QHrealT}
    min_bound::Vector{QHrealT}

    # pnts are Matrix with dimensions (point_dim, num_points)
    # qhull_options is a vector of individual qhull options, e.g. ["Qx", "Qc"]
    function ConvexHull(pnts::Matrix{QHcoordT}, qhull_options::Vector{String}=Vector{String}())
        if size(pnts,1) < 2
            error("qhull requires 2D or higher input")
        end
        qh_ptr = qh_alloc_qh()

        qhull_options = cat(["Qt", "i"], qhull_options, dims=1)
        
        if size(pnts, 1)>=5
            push!(qhull_options, "Qx")
        end

        # make options string
        qh_opts_str = foldl((l,r)->l*" "*r, qhull_options)

        # calculate new qhull
        res = qh_new_qhull(qh_ptr, pnts, qh_opts_str)
        qh_triangulate(qh_ptr)
        
        hd = qh_get_hull_dim(qh_ptr)

        # collect convex hull points
        # for some reason using hd from above in Val(hd) crashes Julia
        simplices = qh_get_convex_hull_pnts(qh_ptr, Val(size(pnts,1)))

        if hd == 2
            vertices = qh_get_extremes_2d(qh_ptr)
        else
            vertices = unique(simplices)
        end
                
        # facet neighbors, equations, good
        facets, neighbors, equations, coplanar, good = qh_get_simplex_facet_arrays(qh_ptr, Val(size(pnts,1)))

        if ("QG" in qhull_options || "QG4" in qhull_options)
            Bool.(good)
        else
            good = Vector{QHboolT}()
        end
        
        # calculate total area and volume
        qh_getarea(qh_ptr, Val(size(pnts,1)))
        area = qh_get_totarea(qh_ptr)
        vol = qh_get_totvol(qh_ptr)

        # max and min bounds
        max_bound = maximum(pnts, dims=2)[:]
        min_bound = minimum(pnts, dims=2)[:]

        # the new Qhull value
        new(qh_ptr, pnts, vertices, simplices, neighbors, equations, coplanar,
            good, area, vol, max_bound, min_bound)
    end    
end


# Build convex hull from a set points
struct Delaunay
    qh_ptr::Ptr{qhT}
    points::Matrix{QHcoordT}
    vertices::Matrix{QHintT}
    simplices::Matrix{QHintT}
    neighbors::Matrix{QHintT}
    equations::Matrix{QHrealT}
    coplanar::Matrix{QHintT}
    good::Vector{QHboolT}
    max_bound::Vector{QHrealT}
    min_bound::Vector{QHrealT}
    paraboloid_scale::QHrealT
    paraboloid_shift::QHrealT
    
    # pnts are Matrix with dimensions (point_dim, num_points)
    # qhull_options is a vector of individual qhull options, e.g. ["Qx", "Qc"]
    function Delaunay(pnts::Matrix{QHcoordT}, qhull_options::Vector{String}=Vector{String}())
        qh_ptr = qh_alloc_qh()


        qhull_options = cat(["d", "Qbb", "Qc", "Qz", "Q12"], qhull_options, dims=1)
        
        if size(pnts, 1)>=5
            push!(qhull_options, "Qx")
        end

        # make options string
        qh_opts_str = foldl((l,r)->l*" "*r, qhull_options)

        # calculate new qhull
        res = qh_new_qhull(qh_ptr, pnts, qh_opts_str)

        qh_triangulate(qh_ptr)
        
        input_dim = qh_ptr.input_dim 
        hd = qh_get_hull_dim(qh_ptr)

        # facet neighbors, equations, good
        facets, neighbors, equations, coplanar, good =
            qh_get_simplex_facet_arrays(qh_ptr, Val(size(pnts,1)+1), delaunay=true)

        # calculate total area and volume
        qh_getarea(qh_ptr, Val(size(pnts,1)))

        # max and min bounds
        max_bound = maximum(pnts, dims=2)[:]
        min_bound = minimum(pnts, dims=2)[:]

        paraboloid_scale, paraboloid_shift = qh_get_paraboloid_shift_scale(qh_ptr)
        
        # the new Delaunay value
        new(qh_ptr, pnts, facets, facets, neighbors, equations, coplanar,
            good, max_bound, min_bound, paraboloid_scale, paraboloid_shift)
    end    
end



# build Voronoi regions for a set of points
struct Voronoi
    qh_ptr::Ptr{qhT}
    points::Matrix{QHcoordT}
    ndim::QHintT
    vertices::Matrix{QHcoordT}
    ridge_points::Matrix{QHintT}
    ridge_vertices::Vector{Vector{QHintT}}
    regions::Vector{Vector{QHintT}}
    point_region::Vector{QHintT}
    max_bound::Vector{QHrealT}
    min_bound::Vector{QHrealT}
    
    # pnts are Matrix with dimensions (point_dim, num_points)
    # qhull_options is a vector of individual qhull options, e.g. ["Qx", "Qc"]
    function Voronoi(pnts::Matrix{QHcoordT}, qhull_options::Vector{String}=Vector{String}())
        if size(pnts,1) < 2
            error("qhull requires 2D or higher input")
        end
        
        qh_ptr = qh_alloc_qh()

        # build Voronoi regions
        qhull_options = cat(["v", "Qbb", "Qc", "Qz"], qhull_options, dims=1)
        #qhull_options = cat(["v", "Qbb"], qhull_options, dims=1) 
        
        if size(pnts, 1)>=5
            push!(qhull_options, "Qx")
        end

        # make options string
        qh_opts_str = foldl((l,r)->l*" "*r, qhull_options)

        # calculate Voronoi regions
        res = qh_new_qhull(qh_ptr, pnts, qh_opts_str)

        input_dim = qh_get_input_dim(qh_ptr)
        hd = qh_get_hull_dim(qh_ptr)

        @assert(size(pnts,1)+1 == qh_ptr.hull_dim)
        voronoi_vertices, ridge_points, ridge_vertices, regions, point_region =
            qh_get_voronoi_diagram(qh_ptr, size(pnts,2), Val(size(pnts,1)+1))

        # max and min bounds
        max_bound = maximum(pnts, dims=2)[:]
        min_bound = minimum(pnts, dims=2)[:]
        
        #(F, C, at_inf) = qh_get_voronoi_pnts(qh_ptr, Val(hd))
        new(qh_ptr, pnts, input_dim, voronoi_vertices, ridge_points, ridge_vertices,
            regions, point_region, max_bound, min_bound)
    end
end

# build Voronoi regions for a set of points
struct HalfspaceIntersection
    qh_ptr::Ptr{qhT}
    halfspaces::Matrix{QHcoordT}
    interior_point::Vector{QHrealT}
    ndim::QHintT
    intersections::Matrix{QHcoordT}
    dual_points::Matrix{QHcoordT}
    dual_facets::Vector{Vector{QHintT}}
    dual_vertices::Vector{QHintT}
    dual_equations::Matrix{QHcoordT}
    dual_area::QHrealT
    dual_volume::QHrealT
    
    # halfspaces are Matrix with dimensions (n_in_eqs, ndim+1)
    # qhull_options is a vector of individual qhull options, e.g. ["Qx", "Qc"]
    function HalfspaceIntersection(halfspaces::Matrix{QHcoordT}, interior_point::Vector{QHcoordT},
                                    qhull_options::Vector{String}=Vector{String}())
        qh_ptr = qh_alloc_qh()

        # build Halfspace intersections
        hs_mode = foldl((l,r)->l*","*string(r), interior_point[2:end], init="H"*string(interior_point[1]))
        qhull_options = cat(hs_mode, qhull_options, dims=1)
        #qhull_options = cat(["v", "Qbb"], qhull_options, dims=1) 
        
        if size(halfspaces, 1)>=6
            push!(qhull_options, "Qx")
        end

        # make options string
        qh_opts_str = foldl((l,r)->l*" "*r, qhull_options)

        # calculate halfspace intersections
        res = qh_new_qhull(qh_ptr, halfspaces, qh_opts_str)

        input_dim = qh_get_input_dim(qh_ptr)
        hd = qh_get_hull_dim(qh_ptr)

        dual_fcts, dual_eqs = qh_get_hull_facets(qh_ptr)
        dual_pnts = qh_get_hull_points(qh_ptr)
        
        intersections = dual_eqs[1:end-1, :] ./ (-dual_eqs[1:end-1, :]) .+ interior_point
        
        if hd == 2
            vertices = qh_get_extremes_2d(qh_ptr)
        else
            vertices = Matrix{QHcoordT}()
        end

        # calculate total area and volume
        qh_getarea(qh_ptr, Val(hd))
        area = qh_get_totarea(qh_ptr)
        vol = qh_get_totvol(qh_ptr)

        
        new(qh_ptr, halfspaces, interior_point, hd, intersections, dual_pnts,
            dual_fcts, vertices, dual_eqs, area, vol)
    end
end

# used to build ridges inside qhull
mutable struct RidgesT
    ridge_error::Union{Nothing, String}
    nridges::Int
    ridge_points::Matrix{QHintT}
    ridge_vertices::Vector{Vector{QHintT}}
end



# calculate new convex hull from the given points and Qhull options
function qh_new_qhull(qh::Ptr{qhT}, pnts::StridedMatrix{Float64}, opts::String)
    ok = ccall((:qh_new_qhull, qh_lib), Cint,
               (Ptr{qhT}, Cint, Cint, Ref{QHcoordT}, QHboolT, Ptr{QHcharT}, Ptr{QHfileT}, Ptr{QHfileT}),
               qh, size(pnts, 1), size(pnts, 2), pnts, false, "qhull " * opts, C_NULL, C_NULL)
    
    return ok
end

function qh_triangulate(qh::Ptr{qhT})
    ccall((:qh_triangulate, qh_lib), Cvoid, (Ptr{qhT},), qh)
end

function qh_getarea(qh::Ptr{qhT}, ::Val{HD}) where HD
    ccall((:qh_getarea, qh_lib), Cvoid, (Ptr{qhT}, Ptr{QHfacetT}), qh, qh_get_facet_list_ptr(qh, Val(HD)))
end
    
# retrieve Qhull internal point id
function qh_pointid(qh::Ptr{qhT}, pnt::Ptr{NTuple{N, QHpointT}}) where N
    id = ccall((:qh_pointid, qh_lib), Cuint,
               (Ptr{qhT}, Ptr{QHpointT}), qh, pnt)
    return id
end
function qh_pointid(qh::Ptr{qhT}, pnt::Ptr{QHpointT})
    id = ccall((:qh_pointid, qh_lib), Cuint,
               (Ptr{qhT}, Ptr{QHpointT}), qh, pnt)
    return id
end

# retrieve Qhull internal point id
function qh_nearvertex(qh::Ptr{qhT}, fct::Ptr{QHfacetT{HD}}, pnt::Ptr{QHpointT}, dist::Array{QHrealT,1}) where HD
    return ccall((:qh_nearvertex, qh_lib), Ptr{QHvertexT{HD}},
                 (Ptr{qhT}, Ptr{QHfacetT{HD}}, Ptr{QHpointT}, Ptr{QHrealT}), qh, fct, pnt, dist)
end

# retrieve Qhull set size
function qh_setsize(qh::Ptr{qhT}, set::Ptr{QHsetT{T}}) where T<:Union{QHintT, Ptr{<:Union{QHsetelemT, NTuple, QHpointT}}}
    ccall((:qh_setsize, qh_lib), Cint, (Ptr{qhT}, Ptr{QHsetT}), qh, set)
end
function qh_setsize(qh::Ptr{qhT}, set::Ptr{QHsetPtrT{T}}) where T<:Union{QHintT, Ptr{<:Union{QHsetelemT, NTuple, QHpointT}}}
    ccall((:qh_setsize, qh_lib), Cint, (Ptr{qhT}, Ptr{QHsetPtrT}), qh, set)
end

# Qhull qh_findgood_all for the given qhT
function qh_findgood_all(qh::Ptr{qhT}, ::Val{N}) where N
    ccall((:qh_findgood_all, qh_lib), Cvoid, (Ptr{qhT}, Ptr{QHfacetT}), qh, qh_get_facet_list_ptr(qh, Val(N)))
end

function qh_setvoronoi_all(qh::Ptr{qhT})
    ccall((:qh_setvoronoi_all, qh_lib), Cvoid, (Ptr{qhT},), qh)
end

function qh_order_vertexneighbors(qh::Ptr{qhT}, vtx::Ptr{QHvertexT{N}}) where N
    ccall((:qh_order_vertexneighbors, qh_lib), Cvoid, (Ptr{qhT}, Ptr{QHvertexT{N}}), qh, vtx)
end

function qh_memfree(qh::Ptr{qhT}, object_ptr::Ptr{T}, insize::QHintT) where T
    ccall((:qh_memfree, qh_lib), Cvoid, (Ptr{qhT}, Ptr{Cvoid}, QHintT), qh, Ptr{Cvoid}(object_ptr), insize)
end

function qh_eachvoronoi_all(qh::Ptr{qhT}, ridges::RidgesT, visit_f::Ptr{Cvoid},
                            isUpper::QHboolT, innerouter::QHintT, inorder::QHboolT)
    ccall((:qh_eachvoronoi_all, qh_lib), QHintT, (Ptr{qhT}, Ref{RidgesT}, Ptr{Cvoid}, QHboolT, QHintT, QHboolT),
          qh, ridges, visit_f, isUpper, innerouter, inorder)
end

# GETTER accessors for plain data types
for (T, getter) in ((:QHintT, :qh_get_hull_dim), (:QHintT, :qh_get_num_facets), (:QHintT, :qh_get_num_points),
                    (:QHintT, :qh_get_num_vertices), (:QHintT, :qh_get_visit_id), (:QHintT, :qh_get_vertex_visit),
                    (:QHrealT, :qh_get_totarea), (:QHrealT, :qh_get_totvol), (:QHuintT, :qh_get_facet_id),
                    (:QHintT, :qh_get_num_good), (:QHintT, :qh_get_input_dim), (:QHboolT, :qh_get_UPPERdelaunay),
                    (:QHintT, :qh_get_center_size), (:QHboolT, :qh_get_SCALElast), (:QHrealT, :qh_get_last_high),
                    (:QHrealT, :qh_get_last_low), (:QHrealT, :qh_get_last_newhigh), (:QHintT, :qh_get_num_visible))
    @eval begin
        function ($getter)(qh::Ptr{qhT})
            ccall(($(QuoteNode(getter)), qh_lib), $T, (Ptr{qhT},), qh)
        end
    end
end

# GETTER for facet list pointer
function qh_get_facet_list_ptr(qh::Ptr{qhT}, ::Val{N}) where N
    ccall((:qh_get_facet_list, qh_lib), Ptr{QHfacetT{N}}, (Ptr{qhT},), qh)
end

# GETTER for first point of points array
function qh_get_first_point_ptr(qh::Ptr{qhT})
    ccall((:qh_get_first_point, qh_lib), Ptr{QHcoordT}, (Ptr{qhT},), qh)
end

# GETTER for facet list as Julia QHfacetT type
@noinline function qh_get_facet_list(qh::Ptr{qhT}, ::Val{N}) where N
    local ptr

    # for some strange reason Julia crashes without the below if    
    if N==1
        ptr = qh_get_facet_list_ptr(qh, Val(1))
    elseif N==2        
        ptr = qh_get_facet_list_ptr(qh, Val(2))
    elseif N==3
        ptr = qh_get_facet_list_ptr(qh, Val(3))
    elseif N==4
        ptr = qh_get_facet_list_ptr(qh, Val(4))
    elseif N==5
        ptr = qh_get_facet_list_ptr(qh, Val(5))
    else
        ptr = qh_get_facet_list_ptr(qh, Val(N))
    end

    if ptr != C_NULL
        return unsafe_load(ptr)
    else
        return nothing
    end        
end

function qh_facetcenter(qh::Ptr{qhT}, vertices_ptr::Ptr{QHsetT{Ptr{QHvertexT{HD}}}}; free_after_load::Bool=false) where HD
    center_pnt = ccall((:qh_facetcenter, qh_lib), Ptr{NTuple{HD, QHrealT}},
                       (Ptr{qhT}, Ptr{QHsetT{Ptr{QHvertexT{HD}}}}), qh, vertices_ptr)
    if center_pnt != C_NULL
        center = unsafe_load(center_pnt)
        if free_after_load
            qh_memfree(qh, center_pnt, qh.center_size)
        end
        return center
    else
        return nothing
    end
end

# GETTER for vertex list pointer
function qh_get_vertex_list_ptr(qh::Ptr{qhT}, ::Val{N}) where N
    ccall((:qh_get_vertex_list, qh_lib), Ptr{QHvertexT{N}}, (Ptr{qhT},), qh)
end

function qh_get_vertex_tail_ptr(qh::Ptr{qhT}, ::Val{N}) where N
    ccall((:qh_get_vertex_tail, qh_lib), Ptr{QHvertexT{N}}, (Ptr{qhT},), qh)
end

function qh_get_vertex_tail(qh::Ptr{qhT}, ::Val{N}) where N
    ptr = qh_get_vertex_tail_ptr(qh, Val(N))
    if ptr != C_NULL
        return unsafe_load(ptr)
    else
        return nothing
    end        
end

# GETTER for facet list pointer
function qh_get_del_vertices_ptr(qh::Ptr{qhT}) 
    ccall((:qh_get_del_vertices, qh_lib), Ptr{QHsetT{Ptr{QHvertexT}}}, (Ptr{qhT},), qh)
end

# GETTER for facet list as Julia QHfacetT type
@noinline function qh_get_vertex_list(qh::Ptr{qhT}, ::Val{N}) where N
    local ptr
    # for some strange reason Julia crashes without the below if
    if N==1
        ptr = qh_get_vertex_list_ptr(qh, Val(1))
    elseif N==2        
        ptr = qh_get_vertex_list_ptr(qh, Val(2))
    elseif N==3
        ptr = qh_get_vertex_list_ptr(qh, Val(3))
    elseif N==4
        ptr = qh_get_vertex_list_ptr(qh, Val(4))
    elseif N==5
        ptr = qh_get_vertex_list_ptr(qh, Val(5))
    else
        ptr = qh_get_facet_list_ptr(qh, Val(N))
    end
    if ptr != C_NULL
        return unsafe_load(ptr)
    else
        return nothing
    end        
end


function Base.getproperty(qh::ConvexHull, fld::Symbol)
    if fld === :hull_dim
        return qh_get_hull_dim(qh.qh_ptr)
    elseif fld === :num_facets
        return qh_get_num_facets(qh.qh_ptr)
    elseif fld === :num_points
        return qh_get_num_points(qh.qh_ptr)
    elseif fld === :num_vertices
        return qh_get_num_vertices(qh.qh_ptr)
    elseif fld === :visit_id
        return qh_get_visit_id(qh.qh_ptr)
    elseif fld === :vertex_visit
        return qh_get_vertex_visit(qh.qh_ptr)
    elseif fld === :facet_list
        # Hull dimension given to facet type so that hull dimension array size is known
        return qh_get_facet_list(qh.qh_ptr, Val(qh.hull_dim))
    elseif fld === :vertex_list
        # Hull dimension given to facet type so that hull dimension array size is known
        return qh_get_vertex_list(qh.qh_ptr, Val(qh.hull_dim))
    else
        return getfield(qh, fld)
    end
end

function Base.getproperty(fct::QHfacetT{HD}, fld::Symbol) where HD
    if fld === :next
        ptr = getfield(fct, :next)
        if ptr == C_NULL
            return nothing
        else
            return unsafe_load(ptr)
        end
    elseif fld === :next_ptr
        return getfield(fct, :next)
    elseif fld === :self_ptr
        # ID=0 is dummy facet, with next=C_NULL
        # (so the facet cannot be updated in this case)
        if (fct.id != 0) 
            return fct.next.previous
        else
            throw(ErrorException("Cannot get self pointer for last facet in facet list."))
        end
    elseif fld === :vertices
        return QHsetT{Ptr{QHvertexT{HD}}}(fct.vertices_ptr)
    elseif fld === :vertices_ptr
        return getfield(fct, :vertices)
    elseif fld === :neighbors
        return QHsetT{Ptr{QHfacetT{HD}}}(fct.neighbors_ptr)
    elseif fld === :neighbors_ptr
        return getfield(fct, :neighbors)
    elseif fld === :coplanarset
        ptr = fct.coplanarset_ptr
        if ptr != C_NULL
            return QHsetT{Ptr{NTuple{HD, QHpointT}}}(ptr)
        else
            return nothing
        end
    elseif fld === :coplanarset_ptr
        return getfield(fct, :coplanarset)
    elseif fld === :coplanar_ptr_set
        ptr = fct.coplanarset_ptr
        if ptr != C_NULL
            return QHsetPtrT{Ptr{QHpointT}}(Ptr{QHsetPtrT{Ptr{QHpointT}}}(ptr))
        else
            return nothing
        end
    elseif fld === :normal
        return unsafe_load(fct.normal_ptr)
    elseif fld === :normal_ptr
        return getfield(fct, :normal)
    elseif fld == :toporient
        return QHboolT( (getfield(fct, :flags)>>12)&1)  # toporient is 13th bit in the flags field
    elseif fld == :simplicial
        return QHboolT( (getfield(fct, :flags)>>13)&1)  # simplicial is 14th bit in the flags field
    elseif fld == :seen
        return QHboolT( (getfield(fct, :flags)>>14)&1)  # seen is 15th bit in the flags field
    elseif fld == :upperdelaunay
        return QHboolT( (getfield(fct, :flags)>>17)&1)  # upperdelaunay is 18th bit in the flags field
    elseif fld == :good
        return QHboolT( (getfield(fct, :flags)>>19)&1)  # good is 20th bit in the flags field
    else
        return getfield(fct, fld)
    end
end


function Base.setproperty!(fct::QHfacetT{HD}, fld::Symbol, value) where HD

    if fld === :seen
        fct.flags = getfield(fct, :flags) | (UInt32(1) << 14) # seen is 15th bit of the flags field
    else
        setfield!(fct, fld, value)
    end
    # store back to qhull, pointer to self is obtained (somewhat dangerously) utilizing the facet linked list
    unsafe_store!(fct.self_ptr, fct)
    return value
end

function Base.getproperty(vtx::QHvertexT{HD}, fld::Symbol) where HD
    if fld === :next
        ptr = vtx.next_ptr
        if ptr == C_NULL
            return nothing
        else
            return unsafe_load(ptr)
        end
    elseif fld === :self
        return unsafe_load(vtx.self_ptr)
    elseif fld === :self_ptr
        # ID=0 is dummy vertex, with next=C_NULL
        # (so the vertex ptr cannot be retrieved in this case)
        if (vtx.id != 0) 
            return vtx.next.previous_ptr
        else
            throw(ErrorException("Cannot get self pointer for last vertex in vertex list."))
        end
    elseif fld === :next_ptr
        return getfield(vtx, :next)
    elseif fld === :previous
        ptr = vtx.previous_ptr
        if ptr == C_NULL
            return nothing
        else
            return unsafe_load(ptr)
        end
    elseif fld === :previous_ptr
        return getfield(vtx, :previous)
    elseif fld === :point
        ptr = getfield(vtx, :point)
        if ptr == C_NULL
            return nothing
        else
            return unsafe_load(ptr)
        end
    elseif fld === :point_ptr
        return getfield(vtx, :point)
    elseif fld === :neighbors_ptr
        return Ptr{QHsetT{Ptr{QHfacetT{3}}}}(getfield(vtx, :neighbors))
    elseif fld === :neighbors
        ptr=vtx.neighbors_ptr
        return QHsetT{Ptr{QHfacetT{3}}}(ptr)
    else
        return getfield(vtx, fld)
    end
end

function Base.setproperty!(vtx::QHvertexT{HD}, fld::Symbol, value) where HD
    if fld === :seen
        vtx.flags = getfield(vtx, :flags) | UInt8(1) # seen is the first bit of the flags field
    else
        setfield!(vtx, fld, value)
    end
    # store back to qhull, pointer to self is obtained (somewhat dangerously) utilizing the vertex linked list
    if (vtx.id != 0) # ID=0 is dummy vertex, with next=C_NULL (so the vertex cannot be updated in this case)
        unsafe_store!(vtx.self_ptr, vtx)
    end
end

# get calculated convex hull points as Julia Int Array
function qh_get_convex_hull_pnts(qh_ptr::Ptr{qhT}, ::Val{HD}) where HD
    n_facets = qh_get_num_facets(qh_ptr)
    
    facet_list = qh_get_facet_list(qh_ptr, Val(HD))

    # convex hull point ids (i.e. indexes to input points to qhull)
    pnts = Matrix{QHuintT}(undef, HD, n_facets)
    
    facet_ix = 1
    for facet in facet_list
        vtxSet = facet.vertices

        vtx_ix = 1
        for vtx in vtxSet            
            pnt_id = qh_pointid(qh_ptr, vtx.point_ptr)

            # +1 to change to 1-based index for Julia from C 0-based index
            pnts[vtx_ix, facet_ix] = pnt_id + 1 
            vtx_ix+=1
        end
        facet_ix+=1
    end
    
    return pnts
end

# get calculated convex hull vertices as Julia Int Array
function qh_get_convex_hull_vertices(qh_ptr::Ptr{qhT}, ::Val{HD}) where HD
    n_vertices = qh_get_num_vertices(qh_ptr)

    vertex_list = qh_get_vertex_list(qh_ptr, Val(HD))

    # convex hull point ids (i.e. indexes to input points to qhull)
    vertices = Vector{QHuintT}(undef, n_vertices)
    
    vertex_ix = 1
    for vtx in vertex_list
        pnt_id = qh_pointid(qh_ptr, vtx.point_ptr)
        vertices[vertex_ix] = pnt_id + 1
        vertex_ix+=1
    end
    
    return vertices
end

# get calculated voroin points as Julia array
function qh_get_voronoi_pnts(qh_ptr::Ptr{qhT}, ::Val{HD}) where HD

    qh_findgood_all(qh_ptr, Val(3))

    num_voronoi_regions = qh_get_num_vertices(qh_ptr) - qh_setsize(qh_ptr, qh_get_del_vertices_ptr(qh_ptr))

    num_voronoi_vertices = qh_get_num_good(qh_ptr)
    
    qh_setvoronoi_all(qh_ptr)

    facet = qh_get_facet_list(qh_ptr, Val(3))
    
    while facet.id != 0
        facet.seen = false
        facet = facet.next
    end

    ni = zeros(Int, num_voronoi_regions)
    
    order_neighbors = qh_get_hull_dim(qh_ptr) == 3
    k = 1
    vertex = qh_get_vertex_list(qh_ptr, Val(HD))

    while vertex.id != 0 # id 0 is dummy vertex at the end of vertex list
        if order_neighbors
            qh_order_vertexneighbors(qh_ptr, vertex.self_ptr)
            # reload vertex (above call "qh_order_vertexneighbors(qh_ptr, vtx_ptr)" invalides vertex neighbor set)
            vertex = vertex.self
        end
        
        infinity_seen = false

        neighborSet = vertex.neighbors
        for neighbor in neighborSet
            if neighbor.upperdelaunay != 0
                if infinity_seen == false
                    infinity_seen = true
                    ni[k] += 1
                end
            else
                neighbor.seen = true
                ni[k] += 1
            end
        end
        k += 1

        vertex = vertex.next
    end
    
    nr = (qh_get_num_points(qh_ptr) > num_voronoi_regions) ? qh_get_num_points(qh_ptr) : num_voronoi_regions

    at_inf = zeros(Bool, nr, 1)
    F = zeros(num_voronoi_vertices+1, qh_get_input_dim(qh_ptr))
    F[1, :] .= Inf

    C = Array{Any,2}(undef, nr, 1)
    fill!(C, Array{Float64,2}(undef,0,0))

    facet = qh_get_facet_list(qh_ptr, Val(HD))
    for facetI=1:qh_ptr.num_facets
        facet.seen = false
        facet = facet.next
    end

    i = 0
    k = 1

    vertex = qh_ptr.vertex_list
    while vertex.id != 0 # id 0 is dummy final vertex of the vertex list
        if qh_ptr.hull_dim == 3
            qh_order_vertexneighbors(qh_ptr, vertex.self_ptr)
            # reload vertex
            vertex = vertex.self
        end
        infinity_seen = false
        idx = qh_pointid(qh_ptr, vertex.point_ptr)
        num_vertices = ni[k]
        k += 1

        if num_vertices == 1
            continue
        end
        facet_list = zeros(Int, num_vertices)

        m = 1

        neighborSet = vertex.neighbors
        for neighbor in neighborSet
            if neighbor.upperdelaunay != 0
                if infinity_seen == 0
                    infinity_seen = true
                    facet_list[m] = 1
                    m += 1
                    at_inf[idx+1] = true
                end
            else
                if neighbor.seen == false
                    i += 1
                    for d = 1:qh.input_dim
                        F[i+1, d] = neighbor.center[d]
                    end
                    neighbor.seen = true
                    neighbor.visitid = i
                end

                facet_list[m] = neighbor.visitid + 1
                m += 1
            end
        end
        C[idx+1] = facet_list
        vertex = vertex.next
    end

    return (F, C, at_inf)
                
end



# Below functions "qh_get_extremes_2d", "qh_get_simplex_facet_arrays",
# "qh_order_vertexneighbors_nd", "qh_get_voronoi_diagram", "qh_visit_voronoi",
# "qh_get_paraboloid_scale" are adapted from Qhull/io.c and
# Scipy/_qhull.pyx/get_extremes_2d with the below BSD license from _qhull.pyx/Scipy
#
# Copyright (C)  Pauli Virtanen, 2010.
#
# Distributed under the same BSD license as Scipy.
#
# 
# Copyright (c) 2001-2002 Enthought, Inc.  2003-2019, SciPy Developers.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above
#   copyright notice, this list of conditions and the following
#   disclaimer in the documentation and/or other materials provided
#   with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its
#   contributors may be used to endorse or promote products derived
#   from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE


function qh_get_extremes_2d(qh_ptr::Ptr{qhT}) 

    # qhull io.c has the below call, Scipy does not
    # This is called from ConvexHull constructor, hence assumed visit_id is valid
    # qh_countfacets(facetlist, facets, printall, &numfacets, &numsimplicial,
    #    &totneighbors, &numridges, &numcoplanars, &numtricoplanars); /* marks qh visit_id */
    # vertices= qh_facetvertices(facetlist, facets, printall);
    # qh_fprintf(fp, 9088, "%d\n", qh_setsize(vertices));
    # qh_settempfree(&vertices);
    
    if (qh_get_num_facets(qh_ptr) == 0)
        return Vector{QHintT}()
    end
    
    # qhull/Scipy update the internal qhT structure fields for the visit ids
    # as the values are only read in the rest of the code, local variables used here
    # (assumed the qh internal value update is not necessary)
    qh_vertex_visit = qh_get_vertex_visit(qh_ptr) + 1
    qh_visit_id = qh_get_visit_id(qh_ptr) + 1

    # Init result array
    extremes = zeros(QHintT, 100)
    n_extremes = 0

    # get first facet in facet list
    facet = qh_get_facet_list(qh_ptr, Val(qh_ptr.hull_dim))
    
    # use facet id instead of pointer comparision for ending the while loop
    start_facet_id = facet.id

    while !isnothing(facet)
        if facet.visitid == qh_visit_id
            throw(ErrorException("Internal Qhull error, loop in facet list"))
        end
        
        if xor(facet.toporient, qh_ORIENTclock) != 0
            vertexA = facet.vertices[1] 
            vertexB = facet.vertices[2]  
            nextfacet = facet.neighbors[1]
        else
            vertexA = facet.vertices[2]  
            vertexB = facet.vertices[1]  
            nextfacet = facet.neighbors[2]
        end
        
        # check if result array needs resizing
        if n_extremes + 2 > length(extremes)
            resize!(extremes, 2*length(extremes)+1)
        end
#        if facet.visitid != 0  # qhull has this check, Scipy does not
            if (vertexA.visitid != qh_vertex_visit)
                # this updates also internal qhull vertex state
                vertexA.visitid = QHuintT(qh_vertex_visit)
                n_extremes += 1            
                extremes[n_extremes] = qh_pointid(qh_ptr, vertexA.point_ptr) + 1 # +1 to change to 1-based index
            end
            if vertexB.visitid != qh_vertex_visit
                vertexB.visitid = QHuintT(qh_vertex_visit)
                n_extremes += 1            
                extremes[n_extremes] = qh_pointid(qh_ptr, vertexB.point_ptr) + 1 # +1 to change to 1-based index
            end
 #       end
        # this updates also internal qhull facet state
        facet.visitid = QHuintT(qh_visit_id);
        facet = nextfacet

        if facet.id == start_facet_id
            break
        end
    end
    
    resize!(extremes, n_extremes)
    return extremes
end

# get calculated convex hull points as Julia Int Array
function qh_get_simplex_facet_arrays(qh_ptr::Ptr{qhT}, ::Val{HD}; delaunay=false) where HD
    facet_list = qh_get_facet_list(qh_ptr, Val(HD))
    
    id_map = fill!(Vector{QHintT}(undef, qh_get_facet_id(qh_ptr)), QHintT(-1))

    j = 1 # 1 based index in Julia
    for facet in facet_list
        if !delaunay || facet.upperdelaunay == qh_ptr.UPPERdelaunay
            if (facet.simplicial == 0) &&
                ((length(facet.vertices) != HD) || (length(facet.neighbors) != HD))
                throw(ErrorException("Non-simplical facet encountered."))
            end
            id_map[facet.id] = j
            j += 1
        end
    end

    n_facets = j-1
    # facet neighors
    neighbors = Matrix{QHintT}(undef, HD, n_facets)
    facets = Matrix{QHintT}(undef, HD, n_facets)
    good = Vector{QHintT}(undef, n_facets)
    equations = Matrix{QHrealT}(undef, HD+1, n_facets)
    coplanar = zeros(QHintT, 10, 3)
    ncoplanar = 1
    
    facet_ix = 1
    for facet in facet_list

        if delaunay && (facet.upperdelaunay != qh_ptr.UPPERdelaunay)
            continue
        end
        
        neighborSet = facet.neighbors

        lower_bound = 1

        if delaunay && facet.toporient == qh_ORIENTclock HD == 3
            # Swap the first and second indices to maintain a
            # counter-clockwise orientation.
            for i in 1:2
                # Save the vertex info
                swapped_index =  i==1 ? 2 : 1
                vertex = facet.vertices[i]
                ipoint = qh_pointid(qh_ptr, vertex.point_ptr)
                facets[swapped_index, facet_ix] = ipoint + 1
                
                # Save the neighbor info
                neighbor = facet.neighbors[i]
                neighbors[swapped_index, facet_ix] = id_map[neighbor.id]
            end
            lower_bound = 3
        end
                        
        for dim in lower_bound:HD
            vertex = facet.vertices[dim]
            ipoint = qh_pointid(qh_ptr, vertex.point_ptr)
            facets[dim, facet_ix] = ipoint+1
            
            neighbor = neighborSet[dim]
            neighbors[dim, facet_ix] = id_map[neighbor.id]
        end

        for ix in 1:HD
            equations[ix, facet_ix] = facet.normal[ix]
        end
        equations[HD+1, facet_ix] = facet.offset

        dist = Array{QHrealT}(undef, 1)

        # Save coplanar info
        if !isnothing(facet.coplanar_ptr_set)
            for point_ptr in facet.coplanar_ptr_set
                vertex = unsafe_load(qh_nearvertex(qh_ptr, facet.self_ptr, point_ptr, dist))
                if ncoplanar >= size(coplanar, 1)
                    # The array is always safe to resize
                    coplanar = cat(coplanar, zeros(QHintT, ncoplanar + 1, HD+1), dims=1)
                end
                coplanar[ncoplanar, 1] = qh_pointid(qh_ptr, point_ptr)
                coplanar[ncoplanar, 2] = id_map[facet.id]
                coplanar[ncoplanar, 3] = qh_pointid(qh_ptr, vertex.point_ptr)
                ncoplanar += 1
            end
        end
        
        # save good info
        good[facet_ix] = facet.good
        facet_ix+=1
    end

    # resize
    coplanar = coplanar[1:ncoplanar-1, :]
    
    return (facets, neighbors, equations, coplanar, good)
end

function qh_visit_voronoi(qh_ptr::Ptr{qhT}, ridges::RidgesT, vertex_ptr::Ptr{QHvertexT{HD}},
                       vertexA_ptr::Ptr{QHvertexT{HD}},
                       centers_ptr::Ptr{QHsetT{Ptr{QHfacetT{HD}}}}, unbounded::QHboolT) where HD
        
    vertex = unsafe_load(vertex_ptr)
    vertexA = unsafe_load(vertexA_ptr)

    if !isnothing(ridges.ridge_error)
        return QHintT(0)
    end

    if ridges.nridges >= size(ridges.ridge_points, 2)
        try
            # The array is guaranteed to be safe to resize
            ridges.ridge_points = cat(ridges.ridge_points, zeros(QHintT, 2, 2*ridges.nridges + 1), dims=2)
        catch e
            ridges.ridge_error = e
            return QHintT(0)
        end
    end

    # Record which points the ridge is between
    point_1 = qh_pointid(qh_ptr, vertex.point_ptr)
    point_2 = qh_pointid(qh_ptr, vertexA.point_ptr)

    ridges.nridges += 1
    ridges.ridge_points[1, ridges.nridges] = point_1
    ridges.ridge_points[2, ridges.nridges] = point_2

    # Record which voronoi vertices constitute the ridge
    cur_vertices = Vector{QHintT}(undef, 0)

    centers = QHsetT{Ptr{QHfacetT{HD}}}(centers_ptr)

    for fct in centers
        ix = fct.visitid - 1
        append!(cur_vertices, ix)
    end
    push!(ridges.ridge_vertices, cur_vertices)

    return QHintT(0)
end


function qh_get_voronoi_diagram(qh_ptr::Ptr{qhT}, num_input_pnts, ::Val{HD}) where HD
    # -- Grab Voronoi ridges    
    ridges = RidgesT(nothing, 0, zeros(QHintT, 2, 10), zeros(QHintT, 0))

    local visit_voronoi_c =
        @cfunction(qh_visit_voronoi, QHintT, (Ptr{qhT}, Ref{RidgesT}, Ptr{QHvertexT{HD}},
                                           Ptr{QHvertexT{HD}}, Ptr{QHsetT{Ptr{QHfacetT{HD}}}}, QHboolT))

    qh_eachvoronoi_all(qh_ptr, ridges, visit_voronoi_c, qh_ptr.UPPERdelaunay,
                       QHintT(qh_RIDGEall), QHuintT(1))

    ridge_points = ridges.ridge_points[:, 1:ridges.nridges]

    if !isnothing(ridges.ridge_error)
        throw(ErrorException(ridges.ridge_error))
    end
    
    # Now, qh_eachvoronoi_all has initialized the visitids of facets
    # to correspond do the Voronoi vertex indices.
    
    # -- Grab Voronoi regions
    regions = Vector{Vector{QHintT}}(undef, 0)
    
    point_region = fill!(Vector{QHintT}(undef, num_input_pnts), -1)

    vertex = qh_ptr.vertex_list
    while vertex.id != 0 # id 0 is dummy last vertex of the vertex list
        qh_order_vertexneighbors_nd(qh_ptr, vertex)
        vertex = vertex.self
        
        i = qh_pointid(qh_ptr, vertex.point_ptr)+1
        if i <= num_input_pnts
            # Qz results to one extra point
            point_region[i] = length(regions)
        end
        
        inf_seen = false
        cur_region = Vector{QHintT}()

        for neighbor in vertex.neighbors
            i = neighbor.visitid - 1
            if i == -1
                if !inf_seen
                    inf_seen = true
                else
                    continue
                end
            end
            append!(cur_region, QHintT(i))
        end

        if length(cur_region) == 1 && cur_region[1] == -1
            # report similarly as qvoronoi o
            cur_region = Vector{QHintT}()
        end

        push!(regions, cur_region)
            
        vertex = vertex.next
    end
        
    # -- Grab Voronoi vertices and point-to-region map
    nvoronoi_vertices = 0
    voronoi_vertices = Matrix{QHrealT}(undef, Int(qh_ptr.input_dim), 10)
    
    facet = qh_ptr.facet_list
    dist = Vector{QHrealT}(undef, 1)
    while facet.id != 0 # id 0 is dummy last facet of the facet list
        if facet.visitid > 0
            # finite Voronoi vertex
            
            center = qh_facetcenter(qh_ptr, facet.vertices_ptr, free_after_load=true)
            
            nvoronoi_vertices = max(facet.visitid, nvoronoi_vertices)
            if nvoronoi_vertices > size(voronoi_vertices, 2)
                # Array is safe to resize
                voronoi_vertices = cat(voronoi_vertices,
                                       zeros(QHrealT, qh_ptr.input_dim, 2*nvoronoi_vertices + 1), dims=2)
            end
            
            for k in 1:qh_ptr.input_dim
                voronoi_vertices[k, facet.visitid] = center[k]
            end
            
            if !isnothing(facet.coplanarset)
                for k in 1:length(facet.coplanarset.e)
                    point = facet.coplanarset[k]
                    vertex = qh_nearvertex(qh_ptr, facet.self_ptr, point.self_ptr, dist)
                    
                    i = qh_pointid(qh_ptr, point)
                    j = qh_pointid(qh_ptr, vertex.point)
                    
                    if i <= num_input_pnts
                        # Qz can result to one extra point
                        point_region[i] = point_region[j]
                    end
                end
            end
        end
        
        facet = facet.next
    end
    
    voronoi_vertices = voronoi_vertices[:, 1:nvoronoi_vertices]
    
    return voronoi_vertices, ridge_points, ridges.ridge_vertices, regions, point_region
    
end

function qh_order_vertexneighbors_nd(qh_ptr::Ptr{qhT}, vertex::QHvertexT{HD}) where HD
    qh_order_vertexneighbors(qh_ptr, vertex.self_ptr)
    ()
end

function qh_get_paraboloid_shift_scale(qh_ptr::Ptr{qhT})
    local paraboloid_scale
    local paraboloid_shift
    
    if qh_ptr.SCALElast != 0
        paraboloid_scale = qh_ptr.last_newhigh / (qh_ptr.last_high - qh_ptr.last_low)
        paraboloid_shift = -qh_ptr.last_low * paraboloid_scale
    else
        paraboloid_scale = 1.0
        paraboloid_shift = 0.0
    end
    
    return paraboloid_scale, paraboloid_shift
end

function qh_get_hull_facets(qh_ptr::Ptr{qhT})
    facet_ndim = qh_ptr.hull_dim       
    
    num_fcts = qh_get_num_facets(qh_ptr) - qh_get_num_visible(qh_ptr)

    equations = zeros(QHcoordT, facet_ndim+1, num_fcts)

    facets = Vector{Vector{QHintT}}()

    i=1
    facet = qh_get_facet_list(qh_ptr, Val(qh_ptr.hull_dim))

    while facet.id != 0
        facetsi = Vector{QHintT}()

        for j = 1:facet_ndim
            equations[j, i] = facet.normal[j]
        end
        equations[facet_ndim+1, i] = facet.offset
        
        for vtx in facet.vertices
            ipoint = qh_pointid(qh_ptr, vtx.point_ptr)+1
            push!(facetsi, ipoint)
        end

        i+=1
        push!(facets, facetsi)
        facet = facet.next
    end

    return facets, equations
end

function qh_get_hull_points(qh_ptr::Ptr{qhT})
    point_ndim = qh_ptr.hull_dim    

    num_points = qh_get_num_points(qh_ptr)
    
    points = Array{QHcoordT}(undef, point_ndim, num_points)

    unsafe_copyto!(pointer(points), qh_ptr.first_point_ptr, point_ndim*num_points)

    return points
end

end
