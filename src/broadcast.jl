using DataArrays, Base.@get!
using Base.Broadcast: bitcache_chunks, bitcache_size, dumpbitcache,
                      promote_eltype, broadcast_shape, eltype_plus, type_minus, type_div,
                      type_pow

# Check that all arguments are broadcast compatible with shape
# Differs from Base in that we check for exact matches
function check_broadcast_shape(shape::Dims, As::Union(AbstractArray,Number)...)
    samesize = true
    for A in As
        if ndims(A) > length(shape)
            error("cannot broadcast array to have fewer dimensions")
        end
        for k in 1:length(shape)
            n, nA = shape[k], size(A, k)
            samesize &= (n == nA)
            if n != nA != 1
                error("array could not be broadcast to match destination")
            end
        end
    end
    samesize
end

# Get ref for value for a PooledDataArray, adding to the pool if
# necessary
_unsafe_pdaref!(Bpool, Brefdict::Dict, val::NAtype) = 0
function _unsafe_pdaref!{K,V}(Bpool, Brefdict::Dict{K,V}, val)
    @get! Brefdict val begin
        push!(Bpool, val)
        convert(V, length(Bpool))
    end
end

# Generate a branch for each possible combination of NA/not NA. This
# gives good performance at the cost of 2^narrays branches.
function gen_na_conds(f, nd, arrtype, outtype, daidx=find([arrtype...] .!= AbstractArray), pos=1, isna=())
    if pos > length(daidx)
        args = Any[symbol("v_$(k)") for k = 1:length(arrtype)]
        for i = 1:length(daidx)
            if isna[i]
                args[daidx[i]] = NA
            end
        end

        # Needs to be gensymmed so that the compiler won't box it
        val = gensym("val")
        quote
            $val = $(Expr(:call, f, args...))
            $(if outtype == DataArray
                :(@inbounds unsafe_dasetindex!(Bdata, Bc, $val, ind))
            elseif outtype == PooledDataArray
                :(@inbounds (@nref $nd Brefs i) = _unsafe_pdaref!(Bpool, Brefdict, $val))
            end)
        end
    else
        k = daidx[pos]
        quote
            if $(symbol("isna_$(k)"))
                $(gen_na_conds(f, nd, arrtype, outtype, daidx, pos+1, tuple(isna..., true)))
            else
                $(if arrtype[k] == DataArray
                    :(@inbounds $(symbol("v_$(k)")) = $(symbol("data_$(k)"))[$(symbol("state_$(k)_0"))])
                else
                    :(@inbounds $(symbol("v_$(k)")) = $(symbol("pool_$(k)"))[$(symbol("r_$(k)"))])
                end)
                $(gen_na_conds(f, nd, arrtype, outtype, daidx, pos+1, tuple(isna..., false)))
            end
        end
    end
end

# Broadcast implementation for DataArrays
#
# TODO: Fall back on faster implementation for same-sized inputs when
# it is safe to do so.
function gen_broadcast_dataarray(nd::Int, arrtype::(DataType...), outtype, f::Function)
    F = Expr(:quote, f)
    narrays = length(arrtype)
    As = [symbol("A_$(i)") for i = 1:narrays]
    dataarrays = find([arrtype...] .== DataArray)
    abstractdataarrays = find([arrtype...] .!= AbstractArray)
    have_fastpath = outtype == DataArray && all(x->!(x <: PooledDataArray), arrtype)

    @eval begin
        local _F_
        function _F_(B::$(outtype), $(As...))
            @assert ndims(B) == $nd

            # Set up input DataArray/PooledDataArrays
            $(Expr(:block, [
                arrtype[k] == DataArray ? quote
                    $(symbol("na_$(k)")) = $(symbol("A_$(k)")).na.chunks
                    $(symbol("data_$(k)")) = $(symbol("A_$(k)")).data
                    $(symbol("state_$(k)_0")) = $(symbol("state_$(k)_$(nd)")) = 1
                    @nexprs $nd d->($(symbol("skip_$(k)_d")) = size($(symbol("data_$(k)")), d) == 1)
                end : arrtype[k] == PooledDataArray ? quote
                    $(symbol("refs_$(k)")) = $(symbol("A_$(k)")).refs
                    $(symbol("pool_$(k)")) = $(symbol("A_$(k)")).pool
                end : nothing
            for k = 1:narrays]...))

            # Set up output DataArray/PooledDataArray
            $(if outtype == DataArray
                quote
                    Bdata = B.data
                    # Copy in case aliased
                    # TODO: check for aliasing?
                    Bna = falses(size(Bdata))
                    Bc = Bna.chunks
                    ind = 1
                end
            elseif outtype == PooledDataArray
                quote
                    Bpool = B.pool = similar(B.pool, 0)
                    Brefs = B.refs
                    Brefdict = Dict{eltype(Bpool),eltype(Brefs)}()
                end
            end)

            @nloops($nd, i, $(outtype == DataArray ? (:Bdata) : (:Brefs)),
                # pre
                d->($(Expr(:block, [
                    arrtype[k] == DataArray ? quote
                        $(symbol("state_$(k)_")){d-1} = $(symbol("state_$(k)_d"));
                        $(symbol("j_$(k)_d")) = $(symbol("skip_$(k)_d")) ? 1 : i_d
                    end : quote
                        $(symbol("j_$(k)_d")) = size($(symbol("A_$(k)")), d) == 1 ? 1 : i_d
                    end
                for k = 1:narrays]...))),

                # post
                d->($(Expr(:block, [quote
                    $(symbol("skip_$(k)_d")) || ($(symbol("state_$(k)_d")) = $(symbol("state_$(k)_0")))
                end for k in dataarrays]...))),

                # body
                begin
                    # Advance iterators for DataArray and determine NA status
                    $(Expr(:block, [
                        arrtype[k] == DataArray ? quote
                            @inbounds $(symbol("isna_$(k)")) = Base.unsafe_bitgetindex($(symbol("na_$(k)")), $(symbol("state_$(k)_0")))
                        end : arrtype[k] == PooledDataArray ? quote
                            @inbounds $(symbol("r_$(k)")) = @nref $nd $(symbol("refs_$(k)")) d->$(symbol("j_$(k)_d"))
                            $(symbol("isna_$(k)")) = $(symbol("r_$(k)")) == 0
                        end : nothing
                    for k = 1:narrays]...))

                    # Extract values for ordinary AbstractArrays
                    $(Expr(:block, [
                        :(@inbounds $(symbol("v_$(k)")) = @nref $nd $(symbol("A_$(k)")) d->$(symbol("j_$(k)_d")))
                    for k = find([arrtype...] .== AbstractArray)]...))

                    # Compute and store return value
                    $(gen_na_conds(F, nd, arrtype, outtype))

                    # Increment state
                    $(Expr(:block, [:($(symbol("state_$(k)_0")) += 1) for k in dataarrays]...))
                    $(if outtype == DataArray
                        :(ind += 1)
                    end)
                end)

            $(if outtype == DataArray
                :(B.na = Bna)
            end)
        end
        _F_
    end
end

datype(A_1::PooledDataArray, As...) = tuple(PooledDataArray, datype(As...)...)
datype(A_1::DataArray, As...) = tuple(DataArray, datype(As...)...)
datype(A_1, As...) = tuple(AbstractArray, datype(As...)...)
datype() = ()

datype_int(A_1::PooledDataArray, As...) = (uint64(2) | (datype_int(As...) << 2))
datype_int(A_1::DataArray, As...) = (uint64(1) | (datype_int(As...) << 2))
datype_int(A_1, As...) = (datype_int(As...) << 2)
datype_int() = uint64(0)

for bsig in (DataArray, PooledDataArray), asig in (Union(Array,BitArray,Number), Any)
    @eval let cache = Dict{Function,Dict{Uint64,Dict{Int,Function}}}()
        function Base.map!(f::Base.Callable, B::$bsig, As::$asig...)
            nd = ndims(B)
            length(As) <= 8 || error("too many arguments")
            samesize = check_broadcast_shape(size(B), As...)
            samesize || error("dimensions must match")
            arrtype = datype_int(As...)

            cache_f    = @get! cache      f        Dict{Uint64,Dict{Int,Function}}()
            cache_f_na = @get! cache_f    arrtype  Dict{Int,Function}()
            func       = @get! cache_f_na nd       gen_broadcast_dataarray(nd, datype(As...), $bsig, f)

            func(B, As...)
            B
        end
        # ambiguity
        Base.map!(f::Base.Callable, B::$bsig, r::Range) =
            invoke(Base.map!, (Base.Callable, $bsig, $asig), f, B, r)
        function Base.broadcast!(f::Function, B::$bsig, As::$asig...)
            nd = ndims(B)
            length(As) <= 8 || error("too many arguments")
            samesize = check_broadcast_shape(size(B), As...)
            arrtype = datype_int(As...)

            cache_f    = @get! cache      f        Dict{Uint64,Dict{Int,Function}}()
            cache_f_na = @get! cache_f    arrtype  Dict{Int,Function}()
            func       = @get! cache_f_na nd       gen_broadcast_dataarray(nd, datype(As...), $bsig, f)

            # println(code_typed(func, typeof(tuple(B, As...))))
            func(B, As...)
            B
        end
    end
end

databroadcast(f::Function, As...) = broadcast!(f, DataArray(promote_eltype(As...), broadcast_shape(As...)), As...)
pdabroadcast(f::Function, As...) = broadcast!(f, PooledDataArray(promote_eltype(As...), broadcast_shape(As...)), As...)

function exreplace!(ex::Expr, search, rep)
    for i = 1:length(ex.args)
        if ex.args[i] == search
            splice!(ex.args, i, rep)
            break
        else
            exreplace!(ex.args[i], search, rep)
        end
    end
    ex
end
exreplace!(ex, search, rep) = ex

macro da_broadcast_vararg(func)
    if (func.head != :function && func.head != :(=)) ||
       func.args[1].head != :call || !isa(func.args[1].args[end], Expr) ||
       func.args[1].args[end].head != :...
        error("@da_broadcast_vararg may only be applied to vararg functions")
    end

    va = func.args[1].args[end]
    defs = Any[]
    for n = 1:4, aa = 0:n-1
        def = deepcopy(func)
        rep = Any[symbol("A_$(i)") for i = 1:n]
        push!(rep, va)
        exreplace!(def.args[2], va, rep)
        rep = cell(n+1)
        for i = 1:aa
            rep[i] = Expr(:(::), symbol("A_$i"), AbstractArray)
        end
        for i = aa+1:n
            rep[i] = Expr(:(::), symbol("A_$i"), Union(DataArray, PooledDataArray))
        end
        rep[end] = Expr(:..., Expr(:(::), va.args[1], AbstractArray))
        exreplace!(def.args[1], va, rep)
        push!(defs, def)
    end
    esc(Expr(:block, defs...))
end

macro da_broadcast_binary(func)
    if (func.head != :function && func.head != :(=)) ||
       func.args[1].head != :call || length(func.args[1].args) != 3
        error("@da_broadcast_binary may only be applied to two-argument functions")
    end
    (f, A, B) = func.args[1].args
    body = func.args[2]
    quote
        $f($A::Union(DataArray, PooledDataArray), $B::Union(DataArray, PooledDataArray)) = $(body)
        $f($A::Union(DataArray, PooledDataArray), $B::AbstractArray) = $(body)
        $f($A::AbstractArray, $B::Union(DataArray, PooledDataArray)) = $(body)
    end
end

# Broadcasting DataArrays returns a DataArray
@da_broadcast_vararg Base.broadcast(f::Function, As...) = databroadcast(f, As...)

# Definitions for operators, 
Base.(:(.*))(A::BitArray, B::Union(DataArray{Bool}, PooledDataArray{Bool})) = databroadcast(*, A, B)
Base.(:(.*))(A::Union(DataArray{Bool}, PooledDataArray{Bool}), B::BitArray) = databroadcast(*, A, B)
@da_broadcast_vararg Base.(:(.*))(As...) = databroadcast(*, As...)
@da_broadcast_binary Base.(:(.%))(A, B) = databroadcast(%, A, B)
@da_broadcast_vararg Base.(:(.+))(As...) = broadcast!(+, DataArray(eltype_plus(As...), broadcast_shape(As...)), As...)
@da_broadcast_binary Base.(:(.-))(A, B) = broadcast!(-, DataArray(type_minus(eltype(A), eltype(B)), broadcast_shape(A,B)), A, B)
@da_broadcast_binary Base.(:(./))(A, B) = broadcast!(/, DataArray(type_div(eltype(A), eltype(B)), broadcast_shape(A, B)), A, B)
@da_broadcast_binary Base.(:(.\))(A, B) = broadcast!(\, DataArray(type_div(eltype(A), eltype(B)), broadcast_shape(A, B)), A, B)
Base.(:(.^))(A::Union(DataArray{Bool}, PooledDataArray{Bool}), B::Union(DataArray{Bool}, PooledDataArray{Bool})) = databroadcast(>=, A, B)
Base.(:(.^))(A::BitArray, B::Union(DataArray{Bool}, PooledDataArray{Bool})) = databroadcast(>=, A, B)
Base.(:(.^))(A::AbstractArray{Bool}, B::Union(DataArray{Bool}, PooledDataArray{Bool})) = databroadcast(>=, A, B)
Base.(:(.^))(A::Union(DataArray{Bool}, PooledDataArray{Bool}), B::BitArray) = databroadcast(>=, A, B)
Base.(:(.^))(A::Union(DataArray{Bool}, PooledDataArray{Bool}), B::AbstractArray{Bool}) = databroadcast(>=, A, B)
@da_broadcast_binary Base.(:(.^))(A, B) = broadcast!(^, DataArray(type_pow(eltype(A), eltype(B)), broadcast_shape(A, B)), A, B)

# XXX is a PDA the right return type for these?
Base.broadcast(f::Function, As::PooledDataArray...) = pdabroadcast(f, As...)
Base.(:(.*))(As::PooledDataArray...) = pdabroadcast(*, As...)
Base.(:(.%))(A::PooledDataArray, B::PooledDataArray) = pdabroadcast(%, A, B)
Base.(:(.+))(As::PooledDataArray...) = broadcast!(+, PooledDataArray(eltype_plus(As...), broadcast_shape(As...)), As...)
Base.(:(.-))(A::PooledDataArray, B::PooledDataArray) =
    broadcast!(-, PooledDataArray(type_minus(eltype(A), eltype(B)), broadcast_shape(A,B)), A, B)
Base.(:(./))(A::PooledDataArray, B::PooledDataArray) =
    broadcast!(/, PooledDataArray(type_div(eltype(A), eltype(B)), broadcast_shape(A, B)), A, B)
Base.(:(.\))(A::PooledDataArray, B::PooledDataArray) =
    broadcast!(\, PooledDataArray(type_div(eltype(A), eltype(B)), broadcast_shape(A, B)), A, B)
Base.(:(.^))(A::PooledDataArray{Bool}, B::PooledDataArray{Bool}) = databroadcast(>=, A, B)
Base.(:(.^))(A::PooledDataArray, B::PooledDataArray) =
    broadcast!(^, PooledDataArray(type_pow(eltype(A), eltype(B)), broadcast_shape(A, B)), A, B)

for (sf, vf) in zip(scalar_comparison_operators, array_comparison_operators)
    @eval begin
        # ambiguity
        $(vf)(A::Union(PooledDataArray{Bool},DataArray{Bool}), B::Union(PooledDataArray{Bool},DataArray{Bool})) =
            broadcast!($sf, DataArray(Bool, broadcast_shape(A, B)), A, B)
        $(vf)(A::Union(PooledDataArray{Bool},DataArray{Bool}), B::AbstractArray{Bool}) =
            broadcast!($sf, DataArray(Bool, broadcast_shape(A, B)), A, B)
        $(vf)(A::AbstractArray{Bool}, B::Union(PooledDataArray{Bool},DataArray{Bool})) =
            broadcast!($sf, DataArray(Bool, broadcast_shape(A, B)), A, B)

        @da_broadcast_binary $(vf)(A, B) = broadcast!($sf, DataArray(Bool, broadcast_shape(A, B)), A, B)
    end
end
