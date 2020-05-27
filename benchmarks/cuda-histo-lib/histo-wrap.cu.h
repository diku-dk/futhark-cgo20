#ifndef HISTO_WRAPPER
#define HISTO_WRAPPER

#include<iostream>
#include "histo-kernels.cu.h"

#ifndef DEBUG_INFO
#define DEBUG_INFO 1
#endif


/**********************/
/*** GPU PROPERTIES ***/
/**********************/

#ifndef GPU_ID
#define GPU_ID 0
#endif

#define MIN(a,b)    (((a) < (b)) ? (a) : (b))
#define MAX(a,b)    (((a) < (b)) ? (b) : (a))

#define GPU_KIND    1 // 1 -> RTX2080Ti; 2 -> GTX1050Ti
#define GLB_K_MIN   2

#if (GPU_KIND==1)
    #define K_RF 0.75
#else // GPU_KIND==2
    #define K_RF 0.5
#endif
#define L2Fract     0.4
#ifndef L2Cache
// 4096MB for RTX2070, 5632MB for RTX2080, 1024MB for GTX1050Ti
    #define L2Cache     (4096*1024)
#endif
#ifndef CLelmsz
    #define CLelmsz     16 // how many elements fit on a L2 cache line
#endif

#ifndef LOCMEMW_PERTHD
#define LOCMEMW_PERTHD 12
#endif

#define NUM_THREADS(n)  min(n, getHWD())


static cudaDeviceProp gpu_props;

inline int getHWD() { 
    return gpu_props.maxThreadsPerMultiProcessor * gpu_props.multiProcessorCount;
}
inline int getMaxBlockSize() {
    return gpu_props.maxThreadsPerBlock;
} 
inline int getSH_MEM_SZ() {
    return gpu_props.sharedMemPerBlock;
} 

void initGPUprops() {
    // 0. querry the hardware
    int nDevices;
    cudaGetDeviceCount(&nDevices);

    if(GPU_ID >= nDevices) {
        printf("ERROR: GPU_ID out of range! Exiting!\n");
        exit(1);
    }

    cudaGetDeviceProperties(&gpu_props, GPU_ID);
#if 1
    int HWD = gpu_props.maxThreadsPerMultiProcessor * gpu_props.multiProcessorCount;
    int BLOCK_SZ = gpu_props.maxThreadsPerBlock;
    int SH_MEM_SZ = gpu_props.sharedMemPerBlock;
    if (DEBUG_INFO) {
        printf("Device name: %s\n", gpu_props.name);
        printf("Number of hardware threads: %d\n", HWD);
        printf("Block size: %d\n", BLOCK_SZ);
        printf("Shared memory size: %d\n", SH_MEM_SZ);
        puts("====");
    }
#endif    
}

/***********************/
/*** Various Helpers ***/
/***********************/
int timeval_subtract(struct timeval *result, struct timeval *t2, struct timeval *t1)
{
    unsigned int resolution=1000000;
    long int diff = (t2->tv_usec + resolution * t2->tv_sec) - (t1->tv_usec + resolution * t1->tv_sec);
    result->tv_sec = diff / resolution;
    result->tv_usec = diff % resolution;
    return (diff<0);
}
void randomInit(int* data, int size) {
    for (int i = 0; i < size; ++i)
        data[i] = rand(); // (float)RAND_MAX;
}

void printInpArray(int* data, int size) {
    printf("[");
    if(size > 0) printf("%di32", data[0]);
    for (int i = 1; i < size; ++i)
        printf(", %d", data[i]);
    printf("]");
}

template<class T>
void zeroOut(T* data, int size) {
    for (int i = 0; i < size; ++i)
        data[i] = 0;
}

template<class HP>
bool validate(typename HP::BETA* A, typename HP::BETA* B, unsigned int sizeAB) {
    const double EPS = 0.0000001;
    for(unsigned int i = 0; i < sizeAB; i++) {
        double diff = fabs( A[i] - B[i] );
        if ( diff > EPS ) {
            //printf("INVALID RESULT at index: %d, diff: %f\n", i, diff);
            std::cout << "INVALID RESULT, index: " << i << " val_A: " << A[i] << ", val_B: " << B[i] << std::endl;;
            return false;
        }
    }
    return true;
}

int gpuAssert(cudaError_t code) {
  if(code != cudaSuccess) {
    printf("GPU Error: %s\n", cudaGetErrorString(code));
    return -1;
  }
  return 0;
}
/**********************************/
/*** Golden Sequntial Histogram ***/
/**********************************/
template<class T>
void goldSeqHisto(const int N, const int H, typename T::ALPHA* input, typename T::BETA* histo) {
    typedef typename T::BETA BETA;
    zeroOut(histo, H);
    for(int i=0; i<N; i++) {
        struct indval<BETA> iv = T::f(H, input[i]);
        histo[iv.index] = T::opScal(histo[iv.index], iv.value);
    }
}

template<class T>
unsigned long
timeGoldSeqHisto(const int N, const int H, typename T::ALPHA* input, typename T::BETA* histo) {
    unsigned long int elapsed;
    struct timeval t_start, t_end, t_diff;
    gettimeofday(&t_start, NULL);

    for(int q=0; q<CPU_RUNS; q++) {
        goldSeqHisto<T>(N, H, input, histo);
    }

    gettimeofday(&t_end, NULL);
    timeval_subtract(&t_diff, &t_end, &t_start);
    elapsed = (t_diff.tv_sec*1e6+t_diff.tv_usec);
    //printf("Sequential Naive version runs in: %lu microsecs\n", elapsed);
    return (elapsed / CPU_RUNS); 
}

/*************************************/
/*** Wrapper for Final Reduce Step ***/
/*************************************/
template<class T>
inline void
reduceAcrossMultiHistos(uint32_t H, uint32_t M, uint32_t B, typename T::BETA* d_histos, typename T::BETA* d_histo) {
    // reduce across subhistograms
    const size_t num_blocks_red = (H + B - 1) / B;
    glbhist_reduce_kernel<T><<< num_blocks_red, B >>>(d_histos, d_histo, H, M);
}

/*******************************/
/*** Local-Memory Histograms ***/
/*******************************/
template<class HP>
void histoShMemInsp ( const int H, const int N
                    , int* M, int* num_chunks
                    , int* num_blocks_res, size_t* shmem_size
                    , typename HP::BETA** d_histos
                    , typename HP::BETA** d_histo
) {
    if( (*d_histos != NULL) || (*d_histo != NULL) ) {
        printf("Illegal use in histoShMemInsp: one of the to-be-allocated pointers not NULL, EXITING!\n");
        exit(1);
    }

    typedef typename HP::BETA BETA;
    const AtomicPrim prim_kind = HP::atomicKind();
    const int BLOCK = gpu_props.maxThreadsPerBlock;

    const int lmem = LOCMEMW_PERTHD * BLOCK * 4;
    const int num_blocks = (NUM_THREADS(N) + BLOCK - 1) / BLOCK;
    const int q_small = 2;
    const int work_asymp_M_max = N / (q_small*num_blocks*H);

    const int elms_per_block = (N + num_blocks - 1) / num_blocks;
    const int el_size = sizeof(BETA) + ( (prim_kind==XCG) ? sizeof(int) : 0 );
    float m_prime = MIN( (lmem*1.0 / el_size), (float)elms_per_block ) / H;


    *M = max(1, min( (int)floor(m_prime), BLOCK ) );
    *M = min(*M, work_asymp_M_max);

    const int len = lmem / (el_size * (*M));
    *num_chunks = (H + len - 1) / len;

    if(*M <= 0) {
        printf("Illegal subhistogram degree: %d, H:%d, EXITING!\n", *M, H);
        exit(2);
    }

    *num_blocks_res = num_blocks;

    const size_t mem_size_histo  = H * sizeof(BETA);
    const size_t mem_size_histos = num_blocks * mem_size_histo;
    cudaMalloc((void**) d_histos, mem_size_histos);
    cudaMalloc((void**) d_histo,  mem_size_histo );

    const int Hchunk = (H + (*num_chunks) - 1) / (*num_chunks);
    *shmem_size = (*M) * Hchunk * el_size;
#if DEBUG_INFO
    printf( "histoShMemInsp: Subhistogram degree: %d, num-chunks: %d, H: %d, Hchunk: %d, atomic_kind= %d, shmem: %ld\n"
          , *M, *num_chunks, H, Hchunk, HP::atomicKind(), *shmem_size );
#endif
}

template<class HP> void
histoShMemExec  ( const int H, const int N
                , const int histos_per_block, const int num_chunks
                , const int num_blocks, const size_t shmem_size
                , typename HP::ALPHA* d_input
                , typename HP::BETA*  d_histos
                , typename HP::BETA*  d_histo
) {
    typedef typename HP::BETA BETA;
    const int    BLOCK  = gpu_props.maxThreadsPerBlock;
    const int    Hchunk = (H + num_chunks - 1) / num_chunks;

    const size_t mem_size_histo  = H * sizeof(BETA);
    const size_t mem_size_histos = num_blocks * mem_size_histo;

    cudaMemset(d_histos, 0, mem_size_histos);
    cudaMemset(d_histo , 0, mem_size_histo );
    for(int k=0; k<num_chunks; k++) {
        const int chunkLB = k*Hchunk;
        const int chunkUB = min(H, (k+1)*Hchunk);

        locMemHwdAddCoopKernel<HP><<< num_blocks, BLOCK, shmem_size >>>
              (N, H, histos_per_block, NUM_THREADS(N), chunkLB, chunkUB, d_input, d_histos);
    }
    // reduce across histograms
    reduceAcrossMultiHistos<HP>(H, num_blocks, 256, d_histos, d_histo);
}

template<class HP>
unsigned long
shmemHistoRunValid  ( const int num_gpu_runs
                    , const int H, const int N
                    , typename HP::ALPHA* d_input
                    , typename HP::BETA* h_ref_histo
) {
    typedef typename HP::BETA BETA;
    int     histos_per_block;
    int     num_chunks;
    int     num_blocks;
    size_t  shmem_size;
    BETA* d_histos = NULL;
    BETA* d_histo  = NULL;
    histoShMemInsp< HP >( H, N
                        , &histos_per_block, &num_chunks
                        , &num_blocks, &shmem_size
                        , &d_histos, &d_histo
                        );

    // dry run
    histoShMemExec< HP >
        ( H, N, histos_per_block, num_chunks
        , num_blocks, shmem_size
        , d_input, d_histos, d_histo
        );
    cudaDeviceSynchronize();
    gpuAssert( cudaPeekAtLastError() );


    unsigned long int elapsed;
    struct timeval t_start, t_end, t_diff;
    gettimeofday(&t_start, NULL); 

    // measure runtime
    for(int q=0; q<num_gpu_runs; q++) {
        histoShMemExec< HP >
            ( H, N, histos_per_block, num_chunks
            , num_blocks, shmem_size
            , d_input, d_histos, d_histo
            );

    }
    cudaDeviceSynchronize();

    gettimeofday(&t_end, NULL);
    timeval_subtract(&t_diff, &t_end, &t_start);
    elapsed = (t_diff.tv_sec*1e6+t_diff.tv_usec);
    gpuAssert( cudaPeekAtLastError() );

    { // validate and free memory
        const size_t mem_size_histo  = H * sizeof(BETA);
        BETA* h_histo = (BETA*)malloc(mem_size_histo);
        cudaMemcpy(h_histo, d_histo, mem_size_histo, cudaMemcpyDeviceToHost);
        bool is_valid = validate<HP>(h_histo, h_ref_histo, H);

        free(h_histo);
        cudaFree(d_histos);
        cudaFree(d_histo);

        if(!is_valid) {
            const int BLOCK  = gpu_props.maxThreadsPerBlock;
            int coop = (BLOCK + histos_per_block - 1) / histos_per_block;
            printf( "locMemHwdAddCoop: Validation FAILS! M:%d, coop:%d, H:%d, atomic_kind:%d, Exiting!\n\n"
                  , histos_per_block, coop, H, HP::atomicKind() );
            exit(1);
        }
    }

    return (elapsed/num_gpu_runs);
}

#if 0
/********************************/
/*** Global-Memory Histograms ***/
/********************************/

void autoGlbChunksSubhists(
                           const AtomicPrim prim_kind, const int RF, const int H, const int N, const int T, const int L2,
                int* M, int* num_chunks ) {
    // For the computation of avg_size on XCG:
    //   In principle we average the size of the lock and of the element-type of histogram
    //   But Futhark uses a tuple-of-array rep: hence we need to average the lock together
    //     with each element type from the tuple.
    const int   avg_size= (prim_kind == XCG)? 3*sizeof(int)/2 : sizeof(int);
    const int   el_size = (prim_kind == XCG)? 3*sizeof(int) : sizeof(int);
    const float optim_k_min = GLB_K_MIN;
    const int q_small = 2;
    const int work_asymp_M_max = N / (q_small*H);
        
    // first part
    float race_exp = max(1.0, (1.0 * K_RF * RF) / ( (4.0*CLelmsz) / avg_size) );
    float coop_min = MIN( (float)T, H/optim_k_min );
    const int Mdeg  = min(work_asymp_M_max, max(1, (int) (T / coop_min)));
    //*num_chunks = (int)ceil( Mdeg*H / ( L2Fract * ((1.0*L2Cache) / el_size) * race_exp ) );
    const int S_nom = Mdeg*H*avg_size; //el_size;  // diference: Futhark using avg_size instead of `el_size` here, and seems to do better!
    const int S_den = (int) (L2Fract * L2Cache * race_exp);
    *num_chunks = (S_nom + S_den - 1) / S_den;
    const int H_chk = (int)ceil( H / (*num_chunks) );
    //const int H_chk = ( L2Fract * ((1.0*L2Cache) / el_size) * race_exp ) / Mdeg;
    //*num_chunks = (H + H_chk - 1) / H_chk;

    // second part
    const float u = (prim_kind == ADD) ? 2.0 : 1.0;
    const float k_max= MIN( L2Fract * ( (1.0*L2Cache) / el_size ) * race_exp, (float)N ) / T;
    const float coop = MIN( T, (u * H_chk) / k_max );
    *M = max( 1, (int)floor(T/coop) );
     
    printf( "CHUNKING branch: race_exp: %f, optim_k_min: %f, k_max: %f, coop: %f, Mdeg: %d, Hold: %d, Hnew: %d, num_chunks: %d, M: %d\n"
            , race_exp, optim_k_min, k_max, coop, Mdeg, H, H_chk, *num_chunks, *M );
}


unsigned long
glbMemHwdAddCoop(AtomicPrim select, const int RF, const int N, const int H, const int B, const int M, const int num_chunks, int* d_input, uint32_t* h_ref_histo) {
    const int T = NUM_THREADS(N);
    const int C = (T + M - 1) / M;
    const int chunk_size = (H + num_chunks - 1) / num_chunks;

#if 0
    const int C = min( T, (int) ceil(H / k) );
    const int M = (T+C-1) / C;
#endif

    if((C <= 0) || (C > T)) {
        printf("Illegal subhistogram degree M: %d, resulting in C:%d for H:%d, XCG?=%d, EXITING!\n", M, C, H, (select==XCG));
        exit(0);
    }
    
    // setup execution parameters
    const size_t num_blocks = (T + B - 1) / B;
    const size_t K = (select == XCG) ? 2 : 1;
    const size_t mem_size_histo  = H * K * sizeof(uint32_t);
    const size_t mem_size_histos = M * mem_size_histo;
    const size_t mem_size_locks  = M * H * sizeof(uint32_t);
    uint32_t* d_histos;
    uint32_t* d_histo;
    int* d_locks;
    uint32_t* h_histo = (uint32_t*)malloc(mem_size_histo);

    cudaMalloc((void**) &d_histos, mem_size_histos);
    cudaMalloc((void**) &d_histo,  mem_size_histo );
    cudaMalloc((void**) &d_locks,  mem_size_locks);
    cudaMemset(d_locks,  0, mem_size_locks );
    cudaMemset(d_histo,  0, mem_size_histo );
    cudaMemset(d_histos, 0, mem_size_histos);
    cudaDeviceSynchronize();

    { // dry run
      for(int k=0; k<num_chunks; k++) {
        if(select == ADD) {
          glbMemHwdAddCoopKernel<ADD, uint32_t><<< num_blocks, B >>>
              (RF, N, H, M, T, k*chunk_size, (k+1)*chunk_size, d_input, d_histos, NULL);
        } else if (select == CAS){
          glbMemHwdAddCoopKernel<CAS, uint32_t><<< num_blocks, B >>>
              (RF, N, H, M, T, k*chunk_size, (k+1)*chunk_size, d_input, d_histos, NULL);
        } else { // select == XCG
          glbMemHwdAddCoopKernel<XCG,uint64_t><<< num_blocks, B >>>
              (RF, N, H, M, T, k*chunk_size, (k+1)*chunk_size, d_input, (uint64_t*)d_histos, d_locks);
        }
      }
      // reduce across subhistograms
      reduceAcrossMultiHistos(select, H, M, B, d_histos, d_histo);
    }
    cudaDeviceSynchronize();
    gpuAssert( cudaPeekAtLastError() );

    const int num_gpu_runs = GPU_RUNS;

    unsigned long int elapsed;
    struct timeval t_start, t_end, t_diff;
    gettimeofday(&t_start, NULL); 

    for(int q=0; q<num_gpu_runs; q++) {
      cudaMemset(d_histos, 0, mem_size_histos);

      for(int k=0; k<num_chunks; k++) {
        if(select == ADD) {
          glbMemHwdAddCoopKernel<ADD, uint32_t><<< num_blocks, B >>>
              (RF, N, H, M, T, k*chunk_size, (k+1)*chunk_size, d_input, d_histos, NULL);
        } else if (select == CAS){
          glbMemHwdAddCoopKernel<CAS, uint32_t><<< num_blocks, B >>>
              (RF, N, H, M, T, k*chunk_size, (k+1)*chunk_size, d_input, d_histos, NULL);
        } else { // select == XCG
          glbMemHwdAddCoopKernel<XCG,uint64_t><<< num_blocks, B >>>
              (RF, N, H, M, T, k*chunk_size, (k+1)*chunk_size, d_input, (uint64_t*)d_histos, d_locks);
        }
      }
      // reduce across subhistograms
      reduceAcrossMultiHistos(select, H, M, B, d_histos, d_histo);
    }
    cudaDeviceSynchronize();

    gettimeofday(&t_end, NULL);
    timeval_subtract(&t_diff, &t_end, &t_start);
    elapsed = (t_diff.tv_sec*1e6+t_diff.tv_usec);
    gpuAssert( cudaPeekAtLastError() );

    { // reduce across histograms and copy to host
        cudaMemcpy(h_histo, d_histo, mem_size_histo, cudaMemcpyDeviceToHost);
    }

    { // validate and free memory
        bool is_valid;

        if (select == XCG) {
            is_valid = validate64((uint64_t*)h_histo, (uint64_t*)h_ref_histo, H); 
        } else {
            is_valid = validate32(h_histo, h_ref_histo, H);
        }

        free(h_histo);
        cudaFree(d_histos);
        cudaFree(d_histo);
        cudaFree(d_locks);

        if(!is_valid) {
            printf( "glbMemHwdAddCoop: Validation FAILS! B:%d, T:%d, N:%d, H:%d, M:%d, coop:%d, XCG:%d, Exiting!\n\n"
                  , B, T, N, H, M, C, (int)(select==XCG) );
            exit(1);
        }
    }

    return (elapsed/num_gpu_runs);
}
#endif // commented global-memory histogram computation!

#endif // HISTO_WRAPPER
