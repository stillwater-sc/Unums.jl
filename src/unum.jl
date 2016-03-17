

abstract AbstractUnum{Ess,Fss} <: Real

immutable Unum{Ess,Fss,I} <: AbstractUnum{Ess,Fss}
    bits::I
    function Unum(bits::I, frombits::Type{Val{true}})
        # avoid conflict with Unum(x::Int)
        new(bits)
    end
end

immutable Ubound{Ess,Fss,I} <: AbstractUnum{Ess,Fss}
    lo::Unum{Ess,Fss,I}
    hi::Unum{Ess,Fss,I}
end


maxubits(Ess,Fss) = 2 + Ess + Fss + 2^Ess + 2^Fss
function unumuint(Ess,Fss)
    b = maxubits(Ess,Fss)
    if b <= 8
        UInt8
    elseif b <= 16
        UInt16
    elseif b <= 32
        UInt32
    elseif b <= 64
        UInt64
    elseif b <= 128
        UInt128
    else
        BigInt
    end
end

fsmax{Ess,Fss,I}(::Type{Unum{Ess,Fss,I}}) =
    (one(I) << Fss)
fsmax(u::Unum) = fsmax(typeof(u))

fmax{Ess,Fss,I}(U::Type{Unum{Ess,Fss,I}}) =
    one(I) << fsmax(U) - one(I)
fmax(u::Unum) = fmax(typeof(u))

esmax{Ess,Fss,I}(::Type{Unum{Ess,Fss,I}}) =
    (one(I) << Ess)
esmax(u::Unum) = esmax(typeof(u))

emax{Ess,Fss,I}(U::Type{Unum{Ess,Fss,I}}) =
    one(I) << esmax(U) - one(I)
emax(u::Unum) = emax(typeof(u))

"smallest possible esize containing unbiased exponent ue"
mines(ue) = Base.ndigits0z(ue-1,2)+1


function unpack{Ess,Fss,I}(v::Unum{Ess,Fss,I})
    bits = v.bits

    fs = (bits & (fsmax(v)-one(I))) + one(I)
    bits >>= Fss

    es = (bits & (esmax(v)-one(I))) + one(I)
    bits >>= Ess

    u = bits & one(I) != 0
    bits >>= 1

    i = one(I) << fs
    f = bits & (i-one(I))

    bits >>= fs

    e = bits & ((one(I) << es)-one(I))
    bits >>= es

    s = bits & one(I) != 0

    (s,e,f,u,es,fs)
end

function call{Ess,Fss,I}(::Type{Unum{Ess,Fss,I}},s,e,f,u,es,fs)
    r = zero(I) | s

    r = (r << es) | e
    r = (r << fs) | f
    r = (r << 1) | u

    r = (r << Ess) | (es-one(I))
    r = (r << Fss) | (fs-one(I))
    Unum{Ess,Fss,I}(I(r),Val{true})
end

function isexact(v::Unum)
    (s,e,f,u,es,fs) = unpack(v)
    !u
end
function isexact(v::Ubound)
    isexact(v.lo) && isexact(v.hi) && v.lo == v.hi
end


expobias(esize) = 1<<(esize-1)-1

# Conversion: §4.9
function convert{Ess,Fss,I}(::Type{Bnum},v::Unum{Ess,Fss,I},r::RoundingMode)
    if (1 << Fss) > get_bigfloat_precision()
        error("insufficient BigFloat precision")
    end

    (s,e,f,u,es,fs) = unpack(v)

    # check for Inf or NaN
    if u
        if e == emax(v) && f == fmax(v)
            return Bnum(NaN,u)
        elseif r == RoundFromZero || r == RoundUp && !s || r == RoundDown && s
            f += 1
        end
    end

    # assumes
    x = if e == 0
        ldexp(BigFloat(f), 1 - expobias(es) - signed(fs))
    elseif e == emax(v) && f == fmax(v)
        BigFloat(Inf)
    else
        ldexp(BigFloat(one(I)<<fs+f), signed(e) - signed(expobias(es)) - signed(fs))
    end
    Bnum(s ? -x : x, u)
end


function convert{Ess,Fss,I}(U::Type{Unum{Ess,Fss,I}},b::Bnum,r::RoundingMode;reduce_f::Bool=true)
    es = esmax(U)
    fs = fsmax(U)
    s = signbit(b.num)

    if isnan(b.num)
        f = fmax(U)
        e = emax(U)
        u = true
        s = false
    elseif isinf(b.num)
        if b.open
            f = fmax(U)-one(I)
            e = emax(U)
            u = true
        else
            f = fmax(U)
            e = emax(U)
            u = false
        end
    elseif b.num == 0
        f = zero(I)
        e = zero(I)
        es = one(I)
        fs = one(I)
        u = b.open
        if u
            # RoundDown => (0,?)
            # RoundUp   => (?,0)
            s = r == RoundUp
        end
    else
        bias = expobias(es)

        e = clamp(exponent(b.num)+bias,0,emax(U))
        u = b.open

        if e == 0
            # subnormal: f = 0_XXXX
            ff = ldexp(b.num, bias-1+fs)
            u |= !isinteger(ff)

            f = trunc(I,abs(round(ff,r)))  # 0_0000 <= f <= 1_0000

            if u && (r==RoundUp && !s || r==RoundDown && s)
                # fix up boundary if necessary
                f -= one(I)
            end

            if f == one(I) << fsmax(U)
                # has been rounded up to 1_0000
                e = one(e)
                f = zero(I)
            end
        else
            # normal: f = 1_XXXX
            ff = ldexp(b.num, bias-e+fs)
            u |= !isinteger(ff)

            i = one(I) << fsmax(U)  #  1_0000
            j = i << 1              # 10_0000
            k = fmax(U)             #  0_1111

            if ff > j
                of = j
                u = true
            else
                of = trunc(I,abs(round(ff,r))) # 1_0000 <= of <= 10_0000
            end

            if u && (r==RoundUp && !s || r==RoundDown && s)
                # fix up boundary if necessary
                if of == i # 1_0000
                    e -= one(e)
                    if e == 0
                        of = k # 0_1111
                    else
                        of = i|k # 1_1111
                    end
                else
                    of -= one(I)
                end
            end

            if e == emax(U)
                # need to handle Infs correctly
                if of >= i|k # 1_1111
                    of = i|k - one(i) # 1_1110
                    u = true
                end
            else
                if of == j # 10_0000
                    of = i|k # 1_0000
                    e += one(e)
                end
            end

            f = of & k
        end

        # reduce f
        if reduce_f || !u
            if u && (r==RoundUp && !s || r==RoundDown && s)
                t = min(trailing_ones(f),fs-1)
                f >>= t
                fs -= I(t)
            else
                t = min(trailing_zeros(f),fs-1)
                f >>= t
                fs -= I(t)
            end
        end

        # reduce e
        if e != 0
            ue = signed(e) - expobias(es)
            es = I(mines(ue))
            e = ue + expobias(es)
        end
    end
    Unum{Ess,Fss,I}(s,e,f,u,es,fs)
end


for op in (:+,:-,:*,:/)
    @eval ($op)(x::AbstractUnum, y::AbstractUnum) =
        convert(result_type(x,y),($op)(convert(Bbound,x),convert(Bbound,y)))
end
for op in (:(==),:(<),:(<=))
    @eval ($op)(x::AbstractUnum, y::AbstractUnum) =
        ($op)(convert(Bbound,x),convert(Bbound,y))
end
for op in (:-,:abs,:sqrt)
    @eval begin
        ($op)(x::AbstractUnum) = convert(result_type(x),($op)(convert(Bbound,x)))
    end
end

signbit(v::Unum) = unpack(v)[1]
signbit(x::Ubound) = signbit(x.lo) # okay, technically not correct



function convert{Ess,Fss,I}(::Type{Ubound{Ess,Fss,I}},x::Bbound)
    U = Unum{Ess,Fss,I}
    Ubound(convert(U,x.lo,RoundDown), convert(U,x.hi,RoundUp))
end
convert(::Type{Bbound},x::Unum) =
    Bbound(convert(Bnum,x,RoundDown), convert(Bnum,x,RoundUp))
convert(::Type{Bbound},x::Ubound) =
    Bbound(convert(Bnum,x.lo,RoundDown), convert(Bnum,x.hi,RoundUp))


print(io::IO, x::AbstractUnum) = print(io,convert(Bbound,x))
show(io::IO, x::AbstractUnum) = print(io,typeof(x),'\n',x)
showcompact(io::IO, x::AbstractUnum) = print(io,x)

function print_bits{Ess,Fss,I}(io::IO, v::Unum{Ess,Fss,I})
    (s,e,f,u,es,fs) = unpack(v)
    print(io,'|')
    print_with_color(:red,io,bin(s))
    print(io,'|')
    print_with_color(:blue,io,bin(e,Int(es)))
    print(io,'|')
    print_with_color(:black,io,bin(f,Int(fs)))
    print(io,'|')
    print_with_color(:magenta,io,bin(u))
    print(io,'|')
    print_with_color(:blue,io,bin(es-1,Int(Ess)))
    print(io,'|')
    print_with_color(:grey,io,bin(fs-1,Int(Fss)))
    print(io,'|')
end
print_bits(v::Unum) = print_bits(STDOUT,v)

# improve complex printing
function Base.complex_show{U<:AbstractUnum}(io::IO, z::Complex{U}, compact::Bool)
    compact || print(io,typeof(z),'\n')
    r, i = reim(z)
    showcompact(io,r)
    print(io, compact ? "+" : " + ")
    showcompact(io, i)
    print(io, "*")
    print(io, "im")
end


"""
The result type of a computational procedure involving Unums
"""
function result_type{EssA,FssA,EssB,FssB}(::AbstractUnum{EssA,FssA},::AbstractUnum{EssB,FssB})
    Ess = max(EssA,EssB)
    Fss = max(FssA,FssB)
    I = unumuint(Ess,Fss)
    Ubound{Ess,Fss,I}
end
function result_type{Ess,Fss}(::AbstractUnum{Ess,Fss})
    I = unumuint(Ess,Fss)
    Ubound{Ess,Fss,I}
end


for Ess = 0:5
    for Fss = 0:7
        @eval begin
            typealias $(symbol(string("Unum",Ess,Fss))) Unum{$Ess,$Fss,$(unumuint(Ess,Fss))}
            typealias $(symbol(string("Ubound",Ess,Fss))) Ubound{$Ess,$Fss,$(unumuint(Ess,Fss))}
        end
    end
end

convert{U<:Unum}(::Type{U},x::U) = x

function convert{U<:Ubound}(::Type{U},x::Unum)
    convert(U,Bbound(convert(Bnum,x,RoundDown), convert(Bnum,x,RoundUp)))
end

function convert(::Type{Bool},x::Unum)
    isexact(x) || throw(InexactError())
    convert(Bool, convert(Bnum,x,RoundDown).num)
end
function convert(::Type{Integer},x::Unum)
    isexact(x) || throw(InexactError())
    convert(Integer, convert(Bnum,x,RoundDown).num)
end
function convert(::Type{Bnum},x::Unum)
    isexact(x) || throw(InexactError())
    convert(Bnum,x,RoundDown)
end

function convert{T<:Real}(::Type{T},x::Unum)
    isexact(x) || throw(InexactError())
    convert(T, convert(Bnum,x,RoundDown).num)
end


convert{U<:Unum}(::Type{U},x::U) = x
function convert{U<:Unum}(::Type{U},x::Unum)
    error("Not implemented")
end
function convert{U<:Unum}(::Type{U},x::Real)
    convert(U, convert(Bnum,x), RoundToZero; reduce_f=false)
end
function convert{U<:Ubound}(::Type{U},x::Real)
    convert(U, convert(Bbound,x))
end



zero{U<:AbstractUnum}(::Type{U}) = convert(U,0)
zero{U<:AbstractUnum}(::U) = convert(U,0)
one{U<:AbstractUnum}(::Type{U}) = convert(U,1)
one{U<:AbstractUnum}(::U) = convert(U,1)


==(x::AbstractUnum,y::Irrational) = false


function ==(x::AbstractUnum,y::Real)
    isexact(x) && convert(BigFloat,x) == y
end
