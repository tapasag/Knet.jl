# broadcasting vector y(1,1,1,w,1...) to an N-dim array x(x,y,z,w,t...)
# y is expected to be a vector to broadcast over x
# this kernel tries to take advantage of data reuse of broadcast operation
# y vector devided by BLOCK_SIZE number of elements between each thread block,
# lets say dimensions are grouped by being lower or higher than broadcast dimension
# for y(1,1,z,1,1...) and x(x,y,z,w,t...), x,y are lower and w,t is higher dims
# each thread block operates over all elements in lower dims
# corresponding to BLOCK_SIZE number of elements in broadcast dimension
# so from (1,1,1,1,1) to (x,y,BLOCK_SIZE,1,1) belongs to first thread block
# multidimsize= multiply dim sizes after broadcast dimension for y(1,1,y,1,1...) to x(x,y,z,w,t...) it is 1*w*t
# brdcastnextstride = stride value of next dimension after broadcasting dimension or zero
#
# performance limitations
# I made tests and for good performance elemenst under broadcast stride should be at least 128 and broadcsat dimension should be 285
#
# if broadcast_dim_stride smaller than BLOCK_SIZE_x,
# it will cause some of the threads to stay idle,
#
#                         for high performance we need > 42 thread block (14 warp*3)
# thread_block_count = broadcast_dim_size/BLOCK_SIZE_y > 42
# broadcast_dim_size > BLOCK_SIZE_y*42
# with BLOCK_SIZE=32, broadcast_dim_size should be > 1344
# so if we have less than 1344 elements in broadcast dim, performance will sour
#  worst 448
#
# this kernel can handle vector size of 65535*32 = 2.097.120 elements
# handling everything might have cause extra overflow, TODO-enis add support for limitless
# warning y cannot be a vector in the first dimension like (x,1,1,1..)
# this is handled by cuda14
#
# explanation of kernel code is not added to prevent increase size of cuda13.cu
# (TODO-enis) provide a link to explanation of kernel index calculations for development

using Knet: broadcast_ops

function cuda13src(f, j=f, ex="$f(xi,yi)")
  sprint() do s
    print(s,"#define BLOCK_SIZE_x 32\n#define BLOCK_SIZE_y 32\n")
    for (T,F) in [("float","$(f)_32"),("double","$(f)_64")]
        print(s,

"""
__global__ void _$(F)_13($T *x,$T *y,$T *z, int brdcastdimstride, int brdcastnextstride,int multidimsize,int A_N) {

    int bx = blockIdx.x;
    int tx = threadIdx.x;
    int ty = threadIdx.y;
    //shufle is slow due to index Access pattern
    //#if (__CUDA_ARCH__ >= 300 )
      //int laneId = threadIdx.x & 0x1f;
      //$T value;
      //if (laneId == 0)
          //value = y[BLOCK_SIZE_y*bx+ty];
      //value = __shfl(value, 0);

    //#else
      __shared__ $T Bs[BLOCK_SIZE_x];
      if( ty==0 )
      {
        int vector_index = BLOCK_SIZE_y*bx+tx;
        Bs[tx]=y[vector_index];
      }
    __syncthreads();

    //#endif

    int Start = (((BLOCK_SIZE_y*bx)+ty)* brdcastdimstride)+tx;
    int Step = BLOCK_SIZE_x;
    if (tx<brdcastdimstride && Start<A_N)
    {
      for (int k=0; k< multidimsize; k++)
      {
        for (int i=Start; i < Start+brdcastdimstride-tx; i+=Step)
        {
          $T xi = x[i];
          //#if (__CUDA_ARCH__ >= 300 )
            //$T yi = value;
          //#else
            $T yi = Bs[ty];
          //#endif
          z[i]=$ex;
        }
        Start +=brdcastnextstride;
    }
  }
}

extern "C" {
  void $(F)_13($T *x,$T *y,$T *z, int brdcastdimstride, int brdcastnextstride,int multidimsize,int A_N, int B_N) {
    dim3 dimBlock(BLOCK_SIZE_x, BLOCK_SIZE_y);
    int n_block = (B_N+BLOCK_SIZE_y-1)/BLOCK_SIZE_y;
    dim3 dimGrid(n_block);
    _$(F)_13<<<dimGrid,dimBlock>>>(x,y,z,brdcastdimstride,brdcastnextstride,multidimsize,A_N);
  }
}
""")
    end
  end
end

for a in broadcast_ops
    if !isa(a,Tuple); a=(a,); end
    print(cuda13src(a...))
end
