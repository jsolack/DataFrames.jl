##
## Join / merge
##

function join_idx(left, right, max_groups)
    ## adapted from Wes McKinney's full_outer_join in pandas (file: src/join.pyx).

    # NA group in location 0

    left_sorter, where, left_count = DataArrays.groupsort_indexer(left, max_groups)
    right_sorter, where, right_count = DataArrays.groupsort_indexer(right, max_groups)

    # First pass, determine size of result set
    tcount = 0
    rcount = 0
    lcount = 0
    for i in 1:(max_groups + 1)
        lc = left_count[i]
        rc = right_count[i]

        if rc > 0 && lc > 0
            tcount += lc * rc
        elseif rc > 0
            rcount += rc
        else
            lcount += lc
        end
    end

    # group 0 is the NA group
    tposition = 0
    lposition = 0
    rposition = 0

    left_pos = 0
    right_pos = 0

    left_indexer = Array(Int, tcount)
    right_indexer = Array(Int, tcount)
    leftonly_indexer = Array(Int, lcount)
    rightonly_indexer = Array(Int, rcount)
    for i in 1:(max_groups + 1)
        lc = left_count[i]
        rc = right_count[i]
        if rc == 0
            for j in 1:lc
                leftonly_indexer[lposition + j] = left_pos + j
            end
            lposition += lc
        elseif lc == 0
            for j in 1:rc
                rightonly_indexer[rposition + j] = right_pos + j
            end
            rposition += rc
        else
            for j in 1:lc
                offset = tposition + (j-1) * rc
                for k in 1:rc
                    left_indexer[offset + k] = left_pos + j
                    right_indexer[offset + k] = right_pos + k
                end
            end
            tposition += lc * rc
        end
        left_pos += lc
        right_pos += rc
    end

    ## (left_sorter, left_indexer, leftonly_indexer,
    ##  right_sorter, right_indexer, rightonly_indexer)
    (left_sorter[left_indexer], left_sorter[leftonly_indexer],
     right_sorter[right_indexer], right_sorter[rightonly_indexer])
end

function DataArrays.PooledDataVecs(df1::AbstractDataFrame,
                        df2::AbstractDataFrame)
    # This method exists to allow merge to work with multiple columns.
    # It takes the columns of each DataFrame and returns a DataArray
    # with a merged pool that "keys" the combination of column values.
    # The pools of the result don't really mean anything.
    dv1, dv2 = PooledDataVecs(df1[1], df2[1])
    refs1 = dv1.refs + 1   # the + 1 handles NA's
    refs2 = dv2.refs + 1
    ngroups = length(dv1.pool) + 1
    for j = 2:ncol(df1)
        dv1, dv2 = PooledDataVecs(df1[j], df2[j])
        for i = 1:length(refs1)
            refs1[i] += (dv1.refs[i]) * ngroups
        end
        for i = 1:length(refs2)
            refs2[i] += (dv2.refs[i]) * ngroups
        end
        ngroups = ngroups * (length(dv1.pool) + 1)
    end
    pool = [1:ngroups]
    (PooledDataArray(DataArrays.RefArray(refs1), pool), PooledDataArray(DataArrays.RefArray(refs2), pool))
end

function DataArrays.PooledDataArray{R}(df::AbstractDataFrame, ::Type{R})
    # This method exists to allow another way for merge to work with
    # multiple columns. It takes the columns of the DataFrame and
    # returns a DataArray with a merged pool that "keys" the
    # combination of column values.
    # Notes:
    #   - I skipped the sort to make it faster.
    #   - Converting each individual one-row DataFrame to a Tuple
    #     might be faster.
    refs = zeros(R, nrow(df))
    poolref = Dict{AbstractDataFrame, Int}()
    pool = Array(Uint64, 0)
    j = 1
    for i = 1:nrow(df)
        val = df[i,:]
        if haskey(poolref, val)
            refs[i] = poolref[val]
        else
            push!(pool, hash(val))
            refs[i] = j
            poolref[val] = j
            j += 1
        end
    end
    return PooledDataArray(DataArrays.RefArray(refs), pool)
end

DataArrays.PooledDataArray(df::AbstractDataFrame) = PooledDataArray(df, DEFAULT_POOLED_REF_TYPE)

function Base.join(df1::AbstractDataFrame,
                   df2::AbstractDataFrame;
                   on::Union(Symbol, Vector{Symbol}) = Symbol[],
                   kind::Symbol = :inner)
    if kind == :cross
        if on != Symbol[]
            throw(ArgumentError("Cross joins don't use argument 'on'."))
        end
        return crossjoin(df1, df2)
    elseif on == Symbol[]
        depwarn("Natural joins are deprecated, use argument 'on'.", :AbstractDataFrame)
        on = intersect(names(df1), names(df2))
        if length(on) > 1
            throw(ArgumentError("Key omitted from join with multiple shared names."))
        end
        #throw(ArgumentError("Missing join argument 'on'."))
    end

    dv1, dv2 = PooledDataVecs(df1[on], df2[on])
    left_indexer, leftonly_indexer, right_indexer, rightonly_indexer =
        join_idx(dv1.refs, dv2.refs, length(dv1.pool))

    if kind == :inner
        return hcat(df1[left_indexer, :], without(df2, on)[right_indexer, :])
    elseif kind == :left
        left = df1[[left_indexer, leftonly_indexer], :]
        right = vcat(without(df2, on)[right_indexer, :],
                     nas(without(df2, on), length(leftonly_indexer)))
        return hcat(left, right)
    elseif kind == :right
        left = vcat(without(df1, on)[left_indexer, :],
                    nas(without(df1, on), length(rightonly_indexer)))
        right = df2[[right_indexer, rightonly_indexer], :]
        return hcat(left, right)
    elseif kind == :outer
        mixed = hcat(df1[left_indexer, :], without(df2, on)[right_indexer, :])
        leftonly = hcat(df1[leftonly_indexer, :],
                        nas(without(df2, on), length(leftonly_indexer)))
        leftonly = leftonly[:, names(mixed)]
        rightonly = hcat(nas(without(df1, on), length(rightonly_indexer)),
                         df2[rightonly_indexer, :])
        rightonly = rightonly[:, names(mixed)]
        return vcat(mixed, leftonly, rightonly)
    elseif kind == :semi
        df1[left_indexer, :]
    elseif kind == :anti
        df1[leftonly_indexer, :]
    else
        throw(ArgumentError("Unknown kind of join requested"))
    end
end

function crossjoin(df1::DataFrame, df2::DataFrame)
    r1, r2 = size(df1, 1), size(df2, 1)
    columns = [[rep(c[2], 1, r2) for c in eachcol(df1)],
               [rep(c[2], r1, 1) for c in eachcol(df2)]]
    colindex = Index(make_unique([names(df1), names(df2)]))
    DataFrame(columns, colindex)
end
