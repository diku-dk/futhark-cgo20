/*
 *
 *
 *  Created on: 27.6.2011
 *      Author: Teemu Rantalaiho (teemu.rantalaiho@helsinki.fi)
 *
 *
 *  Copyright 2011 - 2012 Teemu Rantalaiho
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 *
 *
 *
 */

 /*
  *     Note: This compiles by default to include NPP-based version, but not
  *     Thrust based version - as of now, Thrust based version is not even
  *     working correctly.
  *
  *  Compile with:
  *
  *  nvcc -O4 -arch=<your_arch> -I../ test_image_8b_4C.cu -o test_image_8b_4C -lnpp -L /usr/local/cuda/lib64/
  *
  *  or without NPP (NVIDIA Performance Primitives):
  * 
  *  nvcc -O4 -arch=<your_arch> -DNONPP -I../ test_image_8b_4C.cu -o test_image_8b_4C
  *
  */

#ifndef TESTMAXIDX
#define TESTMAXIDX   256      // 256 keys / indices
#endif

#define TEST_IS_POW2 1
#define NRUNS   1000

#ifdef THRUST
#define ENABLE_THRUST   1   // Enable thrust-based version also (xform-sort_by_key-reduce_by_key)
#else
#define ENABLE_THRUST   0
#endif

#ifndef NONPP
#define ENABLE_NPP      1   // NOTE: In order to link, use: -lnpp -L /usr/local/cuda/lib64/ (or similar)
#else
#define ENABLE_NPP      0
#endif

#ifdef OLDARCH
#define FOR_PRE_FERMI   1
#else
#define FOR_PRE_FERMI   0
#endif


#if ENABLE_NPP
#include <npp.h>
#endif

#include <string>
#include <iostream>
#include <assert.h>

#include "cuda_histogram.h"
/*#include <cuda_runtime_api.h>
#include <cuda_runtime.h>
#include <cuda.h>*/


#if ENABLE_THRUST
#include <thrust/transform_reduce.h>
#include <thrust/functional.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/sort.h>
#include <thrust/binary_search.h>
#include <thrust/adjacent_difference.h>
#include <thrust/inner_product.h>
#endif

#include <stdio.h>

static bool csv = false;

// Always return 1 -> normal histogram - each sample has same weight
template <int channel>
struct test_xformChannel
{
  __host__ __device__
  void operator() (uint4* input, int i, int* result_index, int* results, int nresults) const {
    uint4 idata = input[i];
#pragma unroll
    for (int resIdx = 0; resIdx < 4; resIdx++)
    {
        /*
         * int r = (data >> 16) & 0xFF;
         * int g = (data >>  8) & 0xFF;
         * int b = (data >>  0) & 0xFF;
         */
        // Extract channel
        unsigned int data = ((unsigned int*)(&idata))[resIdx];
        int result = (data >> (8 * channel)) & (TESTMAXIDX-1); //0xFF;
        *result_index++ = result;
        *results++ = 1;
    }
  }
};

struct test_sumfun2 {
  __device__ __host__
  int operator() (int res1, int res2) const{
    return res1 + res2;
  }
};


static void printresImpl (int* res, int nres, const char* descr)
{
    if (descr)
        printf("\n%s:\n", descr);
    if (csv)
    {
      printf("[\n");
      for (int i = 0; i < nres; i++)
          printf("%d\n", res[i]);
      printf("]\n");
    }
    else
    {
      printf("[ ");
      for (int i = 0; i < nres; i++)
          printf(" %d, ", res[i]);
      printf("]\n");
    }
}

static void printres (int* res, int nres, const char* descr)
{
    if (descr)
        printf("\n%s:\n", descr);
    printresImpl(res, nres/4, "Red channel");
    printresImpl(&res[nres/4], nres/4, "Green channel");
    printresImpl(&res[2*nres/4], nres/4, "Blue channel");
    printresImpl(&res[3*nres/4], nres/4, "Alpha channel");
}

static void testHistogram(uint4* INPUT, uint4* hostINPUT, int nPixels,  bool print, bool cpurun, bool npp, void* nppSize, void** nppBuffers, void* nppResBuffer, cudaStream_t* streams)
{
  int nIndex = TESTMAXIDX * 4;
  test_sumfun2 sumFun;
  test_xformChannel<0> redChannel;
  test_xformChannel<1> greenChannel;
  test_xformChannel<2> blueChannel;
  test_xformChannel<3> alphaChannel;

  int* tmpres = (int*)malloc(sizeof(int) * nIndex);
  int* cpures = tmpres;
  int* redres = &tmpres[0];
  int* greenres = &tmpres[TESTMAXIDX];
  int* blueres = &tmpres[TESTMAXIDX*2];
  int* alphares = &tmpres[TESTMAXIDX*3];
  int zero = 0;
  {
    {
      if (print)
        printf("\nTest reduce_by_key:\n\n");
      memset(tmpres, 0, sizeof(int) * nIndex);
      if (cpurun)
        for (int i = 0; i < (nPixels >> 2); i++)
        {
          int index[4];
          int tmp[4];
          redChannel(hostINPUT, i, &index[0], &tmp[0], 4);
          for (int tmpi = 0; tmpi < 4; tmpi++)
              redres[index[tmpi]] = sumFun(redres[index[tmpi]], tmp[tmpi]);
          greenChannel(hostINPUT, i, &index[0], &tmp[0], 4);
          for (int tmpi = 0; tmpi < 4; tmpi++)
              greenres[index[tmpi]] = sumFun(greenres[index[tmpi]], tmp[tmpi]);
          blueChannel(hostINPUT, i, &index[0], &tmp[0], 4);
          for (int tmpi = 0; tmpi < 4; tmpi++)
              blueres[index[tmpi]] = sumFun(blueres[index[tmpi]], tmp[tmpi]);
          alphaChannel(hostINPUT, i, &index[0], &tmp[0], 4);
          for (int tmpi = 0; tmpi < 4; tmpi++)
              alphares[index[tmpi]] = sumFun(alphares[index[tmpi]], tmp[tmpi]);

          //printf("i = %d,  out_index = %d,  out_val = (%.3f, %.3f) \n",i, index, tmp.real, tmp.imag);
        }
      if (print && cpurun)
      {
          printres(cpures, nIndex, "CPU results:");
      }
    }

    if (!cpurun && !npp)
    {
      int* tmpbuf = (int*)nppResBuffer;
      int* redgpures = &tmpbuf[0];
      int* greengpures = &tmpbuf[TESTMAXIDX];
      int* bluegpures = &tmpbuf[TESTMAXIDX*2];
      int* alphagpures = &tmpbuf[TESTMAXIDX*3];
      callHistogramKernel<histogram_atomic_inc, 4>(INPUT, redChannel, /*indexFun,*/ sumFun, 0, (nPixels >> 2), zero, redgpures, TESTMAXIDX, true, streams[0], nppBuffers[0]);
      callHistogramKernel<histogram_atomic_inc, 4>(INPUT, greenChannel, /*indexFun,*/ sumFun, 0, (nPixels >> 2), zero, greengpures, TESTMAXIDX, true, streams[1], nppBuffers[1]);
      callHistogramKernel<histogram_atomic_inc, 4>(INPUT, blueChannel, /*indexFun,*/ sumFun, 0, (nPixels >> 2), zero, bluegpures, TESTMAXIDX, true, streams[2], nppBuffers[2]);
      callHistogramKernel<histogram_atomic_inc, 4>(INPUT, alphaChannel, /*indexFun,*/ sumFun, 0, (nPixels >> 2), zero, alphagpures, TESTMAXIDX, true, streams[3], nppBuffers[3]);
      if(print)
        cudaMemcpy(tmpres, nppResBuffer, sizeof(int) * nIndex, cudaMemcpyDeviceToHost);
    }
    else if (npp)
    {
#if ENABLE_NPP
        NppiSize oSizeROI = *(NppiSize*)nppSize;
        Npp8u* pDeviceBuffer = (Npp8u*)nppBuffers[0];
        Npp32s* histograms[4] = { (Npp32s*)nppResBuffer, ((Npp32s*)nppResBuffer) + TESTMAXIDX, ((Npp32s*)nppResBuffer) + 2*TESTMAXIDX, ((Npp32s*)nppResBuffer) + 3*TESTMAXIDX };
        int level[4] = { TESTMAXIDX + 1, TESTMAXIDX + 1, TESTMAXIDX + 1, TESTMAXIDX + 1 };
        int lowlevel[4] = { 0, 0, 0, 0};
        int uplevel[4] = { TESTMAXIDX, TESTMAXIDX, TESTMAXIDX, TESTMAXIDX };
        nppiHistogramEven_8u_C4R(
            (Npp8u*)INPUT, oSizeROI.width << 2, oSizeROI,
            histograms, level, lowlevel, uplevel,
            pDeviceBuffer);
        cudaMemcpy(tmpres, nppResBuffer, sizeof(int) * nIndex, cudaMemcpyDeviceToHost);
#endif
    }

    if (print && (!cpurun))
    {
      printres(tmpres, nIndex, "GPU results:");
    }

  }
  free(tmpres);
}

#if ENABLE_THRUST

// NOTE: Take advantage here of the fact that this is the classical histogram with all values = 1
// And also that we know before hand the number of indices coming out
static void testHistogramParamThrust(unsigned char* INPUT, int index_0, int index_1, bool print)
{
  int nIndex = TESTMAXIDX;
  int N = index_1 - index_0;
  thrust::device_vector<int> vals_out(nIndex);
  thrust::host_vector<int> h_vals_out(nIndex);
  //thrust::device_vector<int> keys(N);
  thrust::device_ptr<unsigned char> keys(INPUT);
  // Sort the data
  thrust::sort(keys, keys + N);
  // And reduce by key - histogram complete
#if 0
  // Note: This codepath is somewhat slow
  test_sumfun2 mysumfun;
  thrust::device_vector<int> keys_out(nIndex);
  thrust::equal_to<int> binary_pred;
  thrust::reduce_by_key(keys, keys + N, thrust::make_constant_iterator(1), keys_out.begin(), vals_out.begin(), binary_pred, mysumfun);
#else
  // This is taken from the thrust histogram example
  thrust::counting_iterator<int> search_begin(0);
  // Find where are the upper bounds of consecutive keys as indices (ie. partition function)
  thrust::upper_bound(keys, keys + N,
                      search_begin, search_begin + nIndex,
                      vals_out.begin());
// compute the histogram by taking differences of the partition function (cumulative histogram)
  thrust::adjacent_difference(vals_out.begin(), vals_out.end(),
                              vals_out.begin());
#endif
  h_vals_out = vals_out;
  if (print)
      printres(&h_vals_out[0], nIndex, "Thrust results");
}
#endif

void printUsage(void)
{
  printf("\n");
  printf("Test order independent reduce-by-key / histogram algorithm with an image histogram\n\n");
  printf("\tOptions:\n\n");
  printf("\t\t--cpu\t\t Run on CPU serially instead of GPU\n");
  printf("\t\t--print\t\t Print results of algorithm (check validity)\n");
  printf("\t\t--thrust\t Run on GPU but using thrust library\n");
  printf("\t\t--csv\t\t When printing add line-feeds to ease openoffice import...\n");
  printf("\t\t--npp\t\t Use NVIDIA Performance Primitives library (NPP) instead.\n");
  printf("\t\t--3ch\t\t Assume 24bits/pixel interleaved RGB data (default).\n");
  printf("\t\t--4ch\t\t Assume 32bits/pixel interleaved ARGB data.\n");
  printf("\t\t--streams\t\t Use CUDA-streams in computation - one per channel.\n");
  printf("\t\t--load <name>\t Use 32-bit texture data s\n");
}


#ifdef FUTHARK
static void printFuthark(int* input, int nPixels) {
    printf("\n[ %di32", input[0]);
    for(unsigned int i=1; i<nPixels; i++) {
        printf(", %d", input[i]);
    }
    printf(" ]\n");
}
#endif

static void fillInput(int* input, const char* filename, int nPixels, bool ch4)
{
  FILE* file = fopen(filename, "rb");
  //texture->dataRGBA8888 = NULL;
  if (!file)
  {
      char* tmp = (char*)malloc(strlen(filename) + 10);
      if (tmp)
      {
          char* ptr = tmp;
          strcpy(ptr, "../");
          ptr += 3;
          strcpy(ptr, filename);
          file = fopen(tmp, "rb");
      }
  }
  // Read
  if (file)
  {
      unsigned int* data = (unsigned int*)input;
      if (data)
      {
          int i;
          for (i = 0; i < nPixels; i++)
          {
              unsigned int raw = 0;
              int bytesPerPixel = ch4 ? 4 : 3;
              int rsize = fread(&raw, bytesPerPixel, 1, file);
              if (rsize != 1)
              {
                  printf(
                      "Warning: Unexpected EOF in texture %s at idx %d\n",
                      filename, i);
                  break;
              }
              if (ch4)
                  data[i] = raw;
              else
                data[i] = (raw & 0x00FFFFFF) | ((i & 0xFFu) << 24);
/*              r = (raw & 0x00FF0000) >> 16;
              g = (raw & 0x0000FF00) >> 8;
              b = (raw & 0x000000FF) >> 0;
              pixel = 0xFF000000 | (b << 16) | (g << 8) | (r << 0);
              data[i] = pixel;*/
          }
      }
      fclose(file);
  }
}


//#define FUTHARK

int main (int argc, char** argv)
{
  int i;

  bool cpu = false;
  bool print = false;
  bool thrust = false;
  bool npp = false;
  bool ch4 = false;
  bool use_streams = false;

  const char* name = argv[1]; //"logo_small.raw"; //"tex_h.raw"; //"logo_small.raw"; //"feli.raw"; //"texture.raw";

#ifndef FUTHARK
  if(print)
    printUsage();
#endif

  for (i = 0; i < argc; i++)
  {
    if (argv[i] && strcmp(argv[i], "--cpu") == 0)
      cpu = true;
    else if (argv[i] && strcmp(argv[i], "--csv") == 0)
      csv = true;
    else if (argv[i] && strcmp(argv[i], "--npp") == 0)
      npp = true;
    else if (argv[i] && strcmp(argv[i], "--print") == 0)
      print = true;
    else if (argv[i] && strcmp(argv[i], "--thrust") == 0)
      thrust = true;
    else if (argv[i] && strcmp(argv[i], "--4ch") == 0)
      ch4 = true;
    else if (argv[i] && strcmp(argv[i], "--3ch") == 0)
      ch4 = false;
    else if (argv[i] && ((strcmp(argv[i], "--streams") == 0) ||
                         (strcmp(argv[i], "--stream")) == 0) )
      use_streams = true;
    else if (argv[i] && strcmp(argv[i], "--load") == 0)
    {
      if (argc > i + 1)
        name = argv[i + 1];
    }
  }

  {

    int nPixels = 0;
    {
      // Portable way to check filesize with C-apis (of course safe only up to 2GB):
      FILE* file = fopen(name, "rb");
      int error = -1;
      long filesize = 0;

      if (file)
        error = fseek(file, 0, SEEK_END);

      if (error == 0)
      {
        filesize = ftell(file);
#ifndef FUTHARK
        printf("File: %s, filesize = %ld\n", name, filesize);
#endif
        fclose(file);
        if (ch4)
            nPixels = (int)((filesize / 16) << 2);
        else
            nPixels = (int)((filesize / 12) << 2);
        if (nPixels <= 0)
        {
          printf("Filesize is too large or small...Sorry...\n");
          return 1;
        }
      }
      else
      {
        printf("Can't access file: %s, errorcode = %d (man fseek)\n", name, error);
        return error;
      }
    }

    printf("Number of pixels in image: %d\n", nPixels);
    // Allocate keys:
    int* INPUT = NULL;
    int* hostINPUT = (int*)malloc(sizeof(int) * nPixels);
    void* nppBuffers[4] = { NULL, NULL, NULL, NULL };
    void* nppResBuffer = NULL;
    void* nppSize = NULL;
    cudaStream_t streams[4] = { 0, 0, 0, 0 };
#if (ENABLE_NPP == 1)
    NppiSize oSizeROI = {0, 0};
    nppSize = &oSizeROI;
#endif
    assert(hostINPUT);
    fillInput(hostINPUT, name, nPixels, ch4);

#ifdef FUTHARK
    // print to Futhark
    printFuthark(hostINPUT, nPixels);
    exit(0);
#endif

    //printf("Cosmin: Num Pixels: %d\n", nPixels);

    if (!cpu)
    {
      cudaMalloc(&INPUT, sizeof(int) * nPixels);
      assert(INPUT);
      cudaMemcpy(INPUT, hostINPUT, sizeof(int) * nPixels, cudaMemcpyHostToDevice);
      cudaMalloc(&nppResBuffer, sizeof(int) * TESTMAXIDX * 4);
      cudaMemset(nppResBuffer, 0, sizeof(int) * TESTMAXIDX * 4);
    }
    // Create events for timing:
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    if (use_streams)
    {
        for (int sid = 0; sid < 4; sid++)
          cudaStreamCreate(&streams[sid]);
    }


    if (npp)
    {
      #if (ENABLE_NPP == 0)
            printf("Sorry - you did not compile with npp-support -bailing out...\n");
            return 2;
      #else
            int nDeviceBufferSize;
            int levelCounts[] = {TESTMAXIDX + 1, TESTMAXIDX + 1, TESTMAXIDX + 1, TESTMAXIDX + 1 };
            // Start guessing from 4096 and div by two
            int width = 4096;
            int height = nPixels / width;
            while (width > 128)
            {
                if (width * height == nPixels)
                    break;
                width >>= 1;
                height = nPixels / width;
            }
            oSizeROI.width = width;
            oSizeROI.height = height;
            nppiHistogramEvenGetBufferSize_8u_C4R(oSizeROI, levelCounts ,&nDeviceBufferSize);
            cudaMalloc(&nppBuffers[0], nDeviceBufferSize);
      #endif
    }
    else
    {
        int zero = 0;
        int tmpbufsize = getHistogramBufSize<histogram_atomic_inc>(zero , (int)(TESTMAXIDX));
        for (int sid = 0; sid < 4; sid++ )
          cudaMalloc(&nppBuffers[sid], tmpbufsize);
    }

    // Now start timer - we run on stream 0 (default stream):
    cudaEventRecord(start, 0);

    for (i = 0; i < NRUNS; i++)
    {
      if (thrust)
      {
        #if ENABLE_THRUST
          testHistogramParamThrust((unsigned char*)INPUT, 0, 4*nPixels, print);
        #else
          printf("\nTest was compiled without thrust support! Find 'ENABLE_THRUST' in source-code!\n\n Exiting...\n");
          break;
        #endif
      }
      else
      {
        testHistogram((uint4*)INPUT, (uint4*)hostINPUT, nPixels, print, cpu, npp, nppSize, nppBuffers, nppResBuffer, &streams[0]);
      }
      print = false;
      // Run only once all stress-tests
    }
    
    {
        float t_ms;
        cudaEventRecord(stop, 0);
        cudaThreadSynchronize();
        cudaEventElapsedTime(&t_ms, start, stop);
        double t = t_ms * 0.001f;
        double GKps = (((double)nPixels * (double)NRUNS * 4.0)) / (t*1.e9);
        printf("Average Runtime per loop iteration: %fs, Thoughput (Gkeys/s): %3f GK/s \n", t/NRUNS, GKps);
    }

    if (INPUT) cudaFree(INPUT);
    if (hostINPUT) free(hostINPUT);
    for (int sid = 0; sid < 4; sid++) if (nppBuffers[sid]) cudaFree(nppBuffers[sid]);
    if (use_streams) for (int sid = 0; sid < 4; sid++) cudaStreamDestroy(streams[sid]);
    cudaEventDestroy(start);
    cudaEventDestroy(stop);
  }
  return 0;
}

