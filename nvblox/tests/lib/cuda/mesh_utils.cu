/*
Copyright 2022 NVIDIA CORPORATION

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include <cuda_runtime.h>

#include <cub/cub.cuh>

#include <thrust/binary_search.h>
#include <thrust/device_vector.h>
#include <thrust/gather.h>
#include <thrust/remove.h>
#include <thrust/sort.h>
#include <thrust/unique.h>

#include "nvblox/core/hash.h"
#include "nvblox/core/unified_ptr.h"
#include "nvblox/tests/mesh_utils.h"

namespace nvblox {

void weldVerticesThrustAsync(const std::vector<Index3D>& block_indices,
                             BlockLayer<MeshBlock>* mesh_layer,
                             const CudaStream& cuda_stream) {
  for (const Index3D& index : block_indices) {
    MeshBlock::Ptr mesh_block = mesh_layer->getBlockAtIndex(index);

    if (!mesh_block || mesh_block->size() <= 3) {
      continue;
    }

    // Store a copy of the input vertices.
    device_vector<Vector3f> input_vertices;
    input_vertices.copyFromAsync(mesh_block->vertices, CudaStreamOwning());
    device_vector<Vector3f> input_normals;
    input_normals.copyFromAsync(mesh_block->normals, CudaStreamOwning());

    // sort vertices to bring duplicates together
    thrust::sort(thrust::device.on(cuda_stream), mesh_block->vertices.begin(),
                 mesh_block->vertices.end(), VectorCompare<Vector3f>());

    // Find unique vertices and erase redundancies. The iterator will point to
    // the new last index.
    auto iterator = thrust::unique(thrust::device.on(cuda_stream),
                                   mesh_block->vertices.begin(),
                                   mesh_block->vertices.end());

    // Figure out the new size.
    size_t new_size = iterator - mesh_block->vertices.begin();
    mesh_block->vertices.resizeAsync(new_size, CudaStreamOwning());
    mesh_block->normals.resizeAsync(new_size, CudaStreamOwning());

    // Find the indices of the original triangles.
    thrust::lower_bound(thrust::device.on(cuda_stream),
                        mesh_block->vertices.begin(),
                        mesh_block->vertices.end(), input_vertices.begin(),
                        input_vertices.end(), mesh_block->triangles.begin(),
                        VectorCompare<Vector3f>());

    // Reshuffle the normals to match.
    thrust::scatter(thrust::device.on(cuda_stream), input_normals.begin(),
                    input_normals.end(), mesh_block->triangles.begin(),
                    mesh_block->normals.begin());
  }
}

void sortSingleBlockThrustAsync(device_vector<Vector3f>* vertices,
                                const CudaStream& cuda_stream) {
  thrust::sort(thrust::device.on(cuda_stream), vertices->begin(),
               vertices->end(), VectorCompare<Vector3f>());
}

void weldSingleBlockThrustAsync(device_vector<Vector3f>* input_vertices,
                                device_vector<int>* input_indices,
                                device_vector<Vector3f>* output_vertices,
                                device_vector<int>* output_indices,
                                const CudaStream& cuda_stream) {
  output_vertices->copyFromAsync(*input_vertices, CudaStreamOwning());
  output_indices->copyFromAsync(*input_indices, CudaStreamOwning());

  // sort vertices to bring duplicates together
  thrust::sort(thrust::device.on(cuda_stream), output_vertices->begin(),
               output_vertices->end(), VectorCompare<Vector3f>());

  // Find unique vertices and erase redundancies. The iterator will point to
  // the new last index.
  auto iterator =
      thrust::unique(thrust::device.on(cuda_stream), output_vertices->begin(),
                     output_vertices->end());

  // Figure out the new size.
  size_t new_size = iterator - output_vertices->begin();
  output_vertices->resizeAsync(new_size, CudaStreamOwning());

  // Find the indices of the original triangles.
  thrust::lower_bound(thrust::device.on(cuda_stream), output_vertices->begin(),
                      output_vertices->end(), input_vertices->begin(),
                      input_vertices->end(), output_indices->begin(),
                      VectorCompare<Vector3f>());
}

// Block-sorting CUDA kernel
template <int BLOCK_THREADS, int ITEMS_PER_THREAD>
__global__ void blockSortKernel(int num_vals, Vector3f* d_in, Vector3f* d_out) {
  constexpr int kValueScale = 1000;
  typedef cub::BlockRadixSort<uint64_t, BLOCK_THREADS, ITEMS_PER_THREAD,
                              Vector3f>
      BlockRadixSortT;

  // Allocate type-safe, repurposable shared memory for collectives
  __shared__ union { typename BlockRadixSortT::TempStorage sort; } temp_storage;

  // Obtain this block's segment of consecutive keys (blocked across threads)
  uint64_t thread_keys[ITEMS_PER_THREAD];
  Vector3f thread_values[ITEMS_PER_THREAD];
  int block_offset = blockIdx.x * (ITEMS_PER_THREAD * BLOCK_THREADS) +
                     threadIdx.x * ITEMS_PER_THREAD;
  // Fill in the keys from the values.
  // I guess we can just do a for loop. ITEMS_PER_THREAD should be fairly small.

  Index3DHash index_hash;
  for (int i = 0; i < ITEMS_PER_THREAD; i++) {
    if (block_offset + i >= num_vals) {
      // We just pack the key with a large value.
      thread_values[i] = Vector3f::Zero();
      thread_keys[i] = SIZE_MAX;
    } else {
      thread_values[i] = d_in[block_offset + i];
      thread_keys[i] = index_hash(Index3D(thread_values[i].x() * kValueScale,
                                          thread_values[i].y() * kValueScale,
                                          thread_values[i].z() * kValueScale));
    }
  }

  __syncthreads();  // Barrier for smem reuse
  // Collectively sort the keys
  BlockRadixSortT(temp_storage.sort).Sort(thread_keys, thread_values);
  __syncthreads();  // Barrier for smem reuse

  for (int i = 0; i < ITEMS_PER_THREAD; i++) {
    if (block_offset + i < num_vals) {
      d_out[block_offset + i] = thread_values[i];
    }
  }
}

/// ʕ•ᴥ•ʔ
void sortSingleBlockCubAsync(device_vector<Vector3f>* input_vertices,
                             device_vector<Vector3f>* output_vertices,
                             const CudaStream& cuda_stream) {
  // Together this should be >> the max number of vertices in the mesh.
  constexpr int kNumThreads = 128;
  constexpr int kNumItemsPerThread = 16;
  if (input_vertices->size() >= kNumThreads * kNumItemsPerThread) {
    LOG(ERROR) << "Input vertices vector too long!";
  }
  blockSortKernel<kNumThreads, kNumItemsPerThread>
      <<<1, kNumThreads, 0, cuda_stream>>>(input_vertices->size(),
                                           input_vertices->data(),
                                           output_vertices->data());
}

// Block-sorting CUDA kernel
template <int BLOCK_THREADS, int ITEMS_PER_THREAD>
__global__ void blockUniqueKernel(int num_vals, Vector3f* d_in, int* num_out,
                                  Vector3f* d_out) {
  constexpr int kValueScale = 1000;
  typedef cub::BlockDiscontinuity<uint64_t, BLOCK_THREADS> BlockDiscontinuityT;

  // Allocate type-safe, repurposable shared memory for collectives
  __shared__ union {
    typename BlockDiscontinuityT::TempStorage sort;
  } temp_storage;

  // Obtain this block's segment of consecutive keys (blocked across threads)
  uint64_t thread_keys[ITEMS_PER_THREAD];
  Vector3f thread_values[ITEMS_PER_THREAD];
  int head_flags[ITEMS_PER_THREAD];
  int block_offset = blockIdx.x * (ITEMS_PER_THREAD * BLOCK_THREADS) +
                     threadIdx.x * ITEMS_PER_THREAD;
  // Fill in the keys from the values.
  // I guess we can just do a for loop. ITEMS_PER_THREAD should be fairly small.

  Index3DHash index_hash;
  for (int i = 0; i < ITEMS_PER_THREAD; i++) {
    if (block_offset + i >= num_vals) {
      // We just pack the key with a large value.
      thread_values[i] = Vector3f::Zero();
      thread_keys[i] = SIZE_MAX;
    } else {
      thread_values[i] = d_in[block_offset + i];
      thread_keys[i] = index_hash(Index3D(thread_values[i].x() * kValueScale,
                                          thread_values[i].y() * kValueScale,
                                          thread_values[i].z() * kValueScale));
    }
  }

  __shared__ int output_index;
  if (threadIdx.x == 0) {
    output_index = 0;
  }

  __syncthreads();  // Barrier for smem reuse
  // Collectively sort the keys
  BlockDiscontinuityT(temp_storage.sort)
      .FlagHeads(head_flags, thread_keys, cub::Inequality());
  __syncthreads();  // Barrier for smem reuse

  // Cool now write only 1 instance of the unique entries to the output.
  for (int i = 0; i < ITEMS_PER_THREAD; i++) {
    if (block_offset + i < num_vals) {
      if (head_flags[i] == 1) {
        d_out[atomicAdd(&output_index, 1)] = thread_values[i];
      }
    }
  }
  __syncthreads();  // Barrier for smem reuse

  if (threadIdx.x == 0) {
    *num_out = output_index;
  }
}

/// ʕ•ᴥ•ʔ
void uniqueSingleBlockCubAsync(device_vector<Vector3f>* input_vertices,
                               device_vector<Vector3f>* output_vertices,
                               const CudaStream& cuda_stream) {
  // Together this should be >> the max number of vertices in the mesh.
  constexpr int kNumThreads = 128;
  constexpr int kNumItemsPerThread = 16;
  if (input_vertices->size() >= kNumThreads * kNumItemsPerThread) {
    LOG(ERROR) << "Input vertices vector too long!";
  }

  unified_ptr<int> num_out = make_unified<int>(MemoryType::kDevice);
  blockUniqueKernel<kNumThreads, kNumItemsPerThread>
      <<<1, kNumThreads, 0, cuda_stream>>>(
          input_vertices->size(), input_vertices->data(), num_out.get(),
          output_vertices->data());

  cuda_stream.synchronize();
  unified_ptr<int> num_out_host = num_out.clone(MemoryType::kHost);
  output_vertices->resizeAsync(*num_out_host, CudaStreamOwning());
}

template <int BLOCK_THREADS, int ITEMS_PER_THREAD>
__global__ void combinedSingleBlockKernel(int num_vals, Vector3f* d_in,
                                          int* inds_in, int* num_out,
                                          Vector3f* d_out, int* inds_out) {
  constexpr int kValueScale = 1000;
  typedef cub::BlockRadixSort<uint64_t, BLOCK_THREADS, ITEMS_PER_THREAD, int>
      BlockRadixSortT;
  typedef cub::BlockDiscontinuity<uint64_t, BLOCK_THREADS> BlockDiscontinuityT;
  typedef cub::BlockScan<int, BLOCK_THREADS> BlockScanT;

  // Allocate type-safe, repurposable shared memory for collectives
  __shared__ union {
    typename BlockRadixSortT::TempStorage sort;
    typename BlockDiscontinuityT::TempStorage discontinuity;
    typename BlockScanT::TempStorage scan;
  } temp_storage;

  __shared__ int output_index;
  if (threadIdx.x == 0) {
    output_index = 0;
  }

  // First we create a values list which is actually the indicies.

  // Obtain this block's segment of consecutive keys (blocked across threads)
  uint64_t thread_keys[ITEMS_PER_THREAD];
  Vector3f thread_values[ITEMS_PER_THREAD];
  int thread_inds[ITEMS_PER_THREAD];
  int head_flags[ITEMS_PER_THREAD];
  int head_indices[ITEMS_PER_THREAD];
  int block_offset = blockIdx.x * (ITEMS_PER_THREAD * BLOCK_THREADS) +
                     threadIdx.x * ITEMS_PER_THREAD;
  // Fill in the keys from the values.
  // I guess we can just do a for loop. ITEMS_PER_THREAD should be fairly small.

  Index3DHash index_hash;
  for (int i = 0; i < ITEMS_PER_THREAD; i++) {
    if (block_offset + i >= num_vals) {
      // We just pack the key with a large value.
      thread_values[i] = Vector3f::Zero();
      thread_keys[i] = SIZE_MAX;
      thread_inds[i] = -1;
    } else {
      thread_values[i] = d_in[block_offset + i];
      thread_keys[i] = index_hash(Index3D(thread_values[i].x() * kValueScale,
                                          thread_values[i].y() * kValueScale,
                                          thread_values[i].z() * kValueScale));
      thread_inds[i] = inds_in[block_offset + i];
    }
  }

  // We then sort the values.
  __syncthreads();
  // Collectively sort the keys
  BlockRadixSortT(temp_storage.sort).Sort(thread_keys, thread_inds);
  __syncthreads();

  // We remove duplicates.
  __syncthreads();
  // Find when the discontinuities happen.
  BlockDiscontinuityT(temp_storage.discontinuity)
      .FlagHeads(head_flags, thread_keys, cub::Inequality());
  __syncthreads();
  // Get the indices that'll be assigned.
  BlockScanT(temp_storage.scan)
      .InclusiveSum<ITEMS_PER_THREAD>(head_flags, head_indices);
  __syncthreads();

  // Cool now write only 1 instance of the unique entries to the output.
  for (int i = 0; i < ITEMS_PER_THREAD; i++) {
    if (block_offset + i < num_vals) {
      if (head_flags[i] == 1) {
        // Get the proper value out.
        d_out[head_indices[i] - 1] = d_in[thread_inds[i]];
        atomicMax(&output_index, head_indices[i]);
      }
      // For the key of each initial vertex, we find what index it now has.
      inds_out[thread_inds[i]] = head_indices[i] - 1;
    }
  }
  __syncthreads();

  if (threadIdx.x == 0) {
    *num_out = output_index;
  }
}

/// ʕ•ᴥ•ʔʕ•ᴥ•ʔʕ•ᴥ•ʔʕ•ᴥ•ʔʕ•ᴥ•ʔ
void combinedSingleBlockCubAsync(device_vector<Vector3f>* input_vertices,
                                 device_vector<int>* input_indices,
                                 device_vector<Vector3f>* output_vertices,
                                 device_vector<int>* output_indices,
                                 const CudaStream& cuda_stream) {
  // Together this should be >> the max number of vertices in the mesh.
  constexpr int kNumThreads = 128;
  constexpr int kNumItemsPerThread = 16;
  if (input_vertices->size() >= kNumThreads * kNumItemsPerThread) {
    LOG(ERROR) << "Input vertices vector too long!";
  }

  unified_ptr<int> num_out = make_unified<int>(MemoryType::kDevice);
  combinedSingleBlockKernel<kNumThreads, kNumItemsPerThread>
      <<<1, kNumThreads, 0, cuda_stream>>>(
          input_vertices->size(), input_vertices->data(), input_indices->data(),
          num_out.get(), output_vertices->data(), output_indices->data());

  unified_ptr<int> num_out_host = num_out.clone(MemoryType::kHost);
  output_vertices->resizeAsync(*num_out_host, CudaStreamOwning());
}

}  // namespace nvblox