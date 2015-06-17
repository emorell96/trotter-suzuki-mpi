/**
 * Distributed Trotter-Suzuki solver
 * Copyright (C) 2015 Luca Calderaro, 2012-2015 Peter Wittek
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#include <stdio.h>

#if HAVE_CONFIG_H
#include <config.h>
#endif
#include "common.h"
#include "hybrid.h"
#ifdef HAVE_MPI
#include <mpi.h>
#endif

// Class methods
HybridKernel::HybridKernel(double *_p_real, double *_p_imag, double *_external_pot_real, double *_external_pot_imag, double _a, double _b, int matrix_width, int matrix_height, int _halo_x, int _halo_y, int * _periods,
#ifdef HAVE_MPI
                           MPI_Comm _cartcomm,
#endif
                           bool _imag_time):
    threadsPerBlock(BLOCK_X, STRIDE_Y),
    a(_a),
    b(_b),
    external_pot_real(_external_pot_real),
    external_pot_imag(_external_pot_imag),
    sense(0),
    halo_x(_halo_x),
    halo_y(_halo_y),
    imag_time(_imag_time) {

    periods = _periods;
    int rank, coords[2], dims[2] = {0, 0};
#ifdef HAVE_MPI
    cartcomm = _cartcomm;
    MPI_Cart_shift(cartcomm, 0, 1, &neighbors[UP], &neighbors[DOWN]);
    MPI_Cart_shift(cartcomm, 1, 1, &neighbors[LEFT], &neighbors[RIGHT]);
    MPI_Comm_rank(cartcomm, &rank);
    MPI_Cart_get(cartcomm, 2, dims, periods, coords);
#else
    dims[0] = dims[1] = 1;
    rank = 0;
    coords[0] = coords[1] = 0;
#endif
    int inner_start_x = 0, end_x = 0, end_y = 0;
    calculate_borders(coords[1], dims[1], &start_x, &end_x, &inner_start_x, &inner_end_x, matrix_width - 2 * periods[1]*halo_x, halo_x, periods[1]);
    calculate_borders(coords[0], dims[0], &start_y, &end_y, &inner_start_y, &inner_end_y, matrix_height - 2 * periods[0]*halo_y, halo_y, periods[0]);
    tile_width = end_x - start_x;
    tile_height = end_y - start_y;

    // The indices of the last blocks are necessary, because their sizes
    // are different from the rest of the blocks
    size_t last_block_start_x = ((tile_width - block_width) / (block_width - 2 * halo_x) + 1) * (block_width - 2 * halo_x);
    size_t last_block_start_y = ((tile_height - block_height) / (block_height - 2 * halo_y) + 1) * (block_height - 2 * halo_y);
    size_t last_block_width = tile_width - last_block_start_x;
    size_t last_block_height = tile_height - last_block_start_y;

    gpu_tile_width = tile_width - block_width - last_block_width + 4 * halo_x;
    gpu_start_x = block_width - 2 * halo_x;

#ifdef HAVE_MPI
    setDevice(rank, cartcomm);
#endif

    int dev;
    CUDA_SAFE_CALL(cudaGetDevice(&dev));
    cudaDeviceProp deviceProp;
    CUDA_SAFE_CALL(cudaGetDeviceProperties(&deviceProp, dev));
    // Estimating GPU memory requirement: 2 buffers, real and imaginary part,
    // single or double precision, further divided by fixed horizontal width.
    // Also, not the entire device memory is available for the users. 90 %
    // is an estimate.
    size_t max_gpu_rows = 0.9 * deviceProp.totalGlobalMem / (2 * 2 * sizeof(double) * gpu_tile_width);
    // The halos must be accounted for
    max_gpu_rows -= 2 * 2 * 2;
    int n_cpu_rows = tile_height - block_height - last_block_height + 2 * halo_y - max_gpu_rows;
    n_bands_on_cpu = 0;
    if (n_cpu_rows > 0) {
        n_bands_on_cpu = (n_cpu_rows + (block_height - 2 * halo_y) - 1) / (block_height - 2 * halo_y);
    }
#ifdef DEBUG
    printf("Max GPU rows: %d\n", max_gpu_rows);
    printf("GPU columns: %d\n", gpu_tile_width);
    printf("CPU rows %d\n", n_cpu_rows);
    printf("%d\n", n_bands_on_cpu);
#endif
    gpu_tile_height = tile_height - (n_bands_on_cpu + 1) * (block_height - 2 * halo_y) - last_block_height + 2 * halo_y;
    gpu_start_y = (n_bands_on_cpu + 1) * (block_height - 2 * halo_y);
#ifdef DEBUG
    printf("%d %d %d %d\n", gpu_start_x, gpu_tile_width, gpu_start_y, gpu_tile_height);
#endif

    p_real[0] = _p_real;
    p_imag[0] = _p_imag;
    p_real[1] = new double[tile_width * tile_height];
    p_imag[1] = new double[tile_width * tile_height];

    CUDA_SAFE_CALL(cudaMalloc(reinterpret_cast<void**>(&pdev_real[0]), gpu_tile_width * gpu_tile_height * sizeof(double)));
    CUDA_SAFE_CALL(cudaMalloc(reinterpret_cast<void**>(&pdev_real[1]), gpu_tile_width * gpu_tile_height * sizeof(double)));
    CUDA_SAFE_CALL(cudaMalloc(reinterpret_cast<void**>(&pdev_imag[0]), gpu_tile_width * gpu_tile_height * sizeof(double)));
    CUDA_SAFE_CALL(cudaMalloc(reinterpret_cast<void**>(&pdev_imag[1]), gpu_tile_width * gpu_tile_height * sizeof(double)));
    CUDA_SAFE_CALL(cudaMalloc(reinterpret_cast<void**>(&dev_external_pot_real), gpu_tile_width * gpu_tile_height * sizeof(double)));
    CUDA_SAFE_CALL(cudaMalloc(reinterpret_cast<void**>(&dev_external_pot_imag), gpu_tile_width * gpu_tile_height * sizeof(double)));
    CUDA_SAFE_CALL(cudaMemcpy2D(dev_external_pot_real, gpu_tile_width * sizeof(double), &(external_pot_real[gpu_start_y * tile_width + gpu_start_x]), tile_width * sizeof(double), gpu_tile_width * sizeof(double), gpu_tile_height, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy2D(dev_external_pot_imag, gpu_tile_width * sizeof(double), &(external_pot_imag[gpu_start_y * tile_width + gpu_start_x]), tile_width * sizeof(double), gpu_tile_width * sizeof(double), gpu_tile_height, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy2D(pdev_real[0], gpu_tile_width * sizeof(double), &(p_real[0][gpu_start_y * tile_width + gpu_start_x]), tile_width * sizeof(double), gpu_tile_width * sizeof(double), gpu_tile_height, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy2D(pdev_imag[0], gpu_tile_width * sizeof(double), &(p_imag[0][gpu_start_y * tile_width + gpu_start_x]), tile_width * sizeof(double), gpu_tile_width * sizeof(double), gpu_tile_height, cudaMemcpyHostToDevice));
    cudaStreamCreate(&stream);

#ifdef HAVE_MPI
    // Halo exchange uses wave pattern to communicate
    // halo_x-wide inner rows are sent first to left and right
    // Then full length rows are exchanged to the top and bottom
    int count = inner_end_y - inner_start_y;	// The number of rows in the halo submatrix
    int block_length = halo_x;	// The number of columns in the halo submatrix
    int stride = tile_width;	// The combined width of the matrix with the halo
    MPI_Type_vector (count, block_length, stride, MPI_DOUBLE, &verticalBorder);
    MPI_Type_commit (&verticalBorder);

    count = halo_y;	// The vertical halo in rows
    block_length = tile_width;	// The number of columns of the matrix
    stride = tile_width;	// The combined width of the matrix with the halo
    MPI_Type_vector (count, block_length, stride, MPI_DOUBLE, &horizontalBorder);
    MPI_Type_commit (&horizontalBorder);
#endif
}

HybridKernel::~HybridKernel() {
    delete[] p_real[0];
    delete[] p_real[1];
    delete[] p_imag[0];
    delete[] p_imag[1];
    delete[] external_pot_real;
    delete[] external_pot_imag;

    CUDA_SAFE_CALL(cudaFree(pdev_real[0]));
    CUDA_SAFE_CALL(cudaFree(pdev_real[1]));
    CUDA_SAFE_CALL(cudaFree(pdev_imag[0]));
    CUDA_SAFE_CALL(cudaFree(pdev_imag[1]));
    CUDA_SAFE_CALL(cudaFree(dev_external_pot_real));
    CUDA_SAFE_CALL(cudaFree(dev_external_pot_imag));

    cudaStreamDestroy(stream);
}


void HybridKernel::run_kernel() {
    // Note that the async CUDA calculations are launched in run_kernel_on_halo
    int inner = 1, sides = 0;
    size_t last_band = (n_bands_on_cpu + 1) * (block_height - 2 * halo_y);
    if (tile_height - block_height < last_band ) {
        last_band = tile_height - block_height;
    }
    int block_start;
    #pragma omp parallel default(shared) private(block_start)
    {
        #pragma omp for schedule(runtime) nowait
        for (block_start = block_height - 2 * halo_y; block_start < (int)last_band; block_start += block_height - 2 * halo_y) {
            process_band(tile_width, block_width, block_height, halo_x, block_start, block_height, halo_y, block_height - 2 * halo_y, a, b, external_pot_real, external_pot_imag, p_real[sense], p_imag[sense], p_real[1 - sense], p_imag[1 - sense], inner, sides, imag_time);
        }
    }
    #pragma omp barrier
    sense = 1 - sense;
}

void HybridKernel::run_kernel_on_halo() {
    // The hybrid kernel is efficient if the CUDA stream is launched first for
    // the inner part of the matrix
    int inner = 1, horizontal = 0, vertical = 0;
    numBlocks.x = (gpu_tile_width  + (BLOCK_X - 2 * halo_x) - 1) / (BLOCK_X - 2 * halo_x);
    numBlocks.y = (gpu_tile_height + (BLOCK_Y - 2 * halo_y) - 1) / (BLOCK_Y - 2 * halo_y);

    cc2kernel_wrapper(gpu_tile_width, gpu_tile_height, -BLOCK_X + 3 * halo_x, -BLOCK_Y + 3 * halo_y, halo_x, halo_y, numBlocks, threadsPerBlock, stream,  a, b, dev_external_pot_real, dev_external_pot_imag, pdev_real[sense], pdev_imag[sense], pdev_real[1 - sense], pdev_imag[1 - sense], inner, horizontal, vertical, imag_time);

    // The CPU calculates the halo
    inner = 0;
    int sides = 0;
    if (tile_height <= block_height) {
        // One full band
        inner = 1;
        sides = 1;
        process_band(tile_width, block_width, block_height, halo_x, 0, tile_height, 0, tile_height, a, b, external_pot_real, external_pot_imag, p_real[sense], p_imag[sense], p_real[1 - sense], p_imag[1 - sense], inner, sides, imag_time);
    }
    else {
#ifdef _OPENMP
        int block_start;
        #pragma omp parallel default(shared) private(block_start)
        {
            #pragma omp sections nowait
            {
                #pragma omp section
                {
                    // First band
                    inner = 1;
                    sides = 1;
                    process_band(tile_width, block_width, block_height, halo_x, 0, block_height, 0, block_height - halo_y, a, b, external_pot_real, external_pot_imag, p_real[sense], p_imag[sense], p_real[1 - sense], p_imag[1 - sense], inner, sides, imag_time);

                }
                #pragma omp section
                {
                    // Last band
                    block_start = ((tile_height - block_height) / (block_height - 2 * halo_y) + 1) * (block_height - 2 * halo_y);
                    inner = 1;
                    sides = 1;
                    process_band(tile_width, block_width, block_height, halo_x, block_start, tile_height - block_start, halo_y, tile_height - block_start - halo_y, a, b, external_pot_real, external_pot_imag, p_real[sense], p_imag[sense], p_real[1 - sense], p_imag[1 - sense], inner, sides, imag_time);

                }
            }

            #pragma omp for schedule(runtime) nowait
            for (block_start = block_height - 2 * halo_y; block_start < (int)(tile_height - block_height); block_start += block_height - 2 * halo_y) {
                inner = 0;
                sides = 1;
                process_band(tile_width, block_width, block_height, halo_x, block_start, block_height, halo_y, block_height - 2 * halo_y, a, b, external_pot_real, external_pot_imag, p_real[sense], p_imag[sense], p_real[1 - sense], p_imag[1 - sense], inner, sides, imag_time);
            }

            #pragma omp barrier
        }

#else
        // Sides
        inner = 0;
        sides = 1;
        int block_start;
        for (block_start = block_height - 2 * halo_y; block_start < tile_height - block_height; block_start += block_height - 2 * halo_y) {
            process_band(tile_width, block_width, block_height, halo_x, block_start, block_height, halo_y, block_height - 2 * halo_y, a, b, external_pot_real, external_pot_imag, p_real[sense], p_imag[sense], p_real[1 - sense], p_imag[1 - sense], inner, sides, imag_time);
        }
        // First band
        inner = 1;
        sides = 1;
        process_band(tile_width, block_width, block_height, halo_x, 0, block_height, 0, block_height - halo_y, a, b, external_pot_real, external_pot_imag, p_real[sense], p_imag[sense], p_real[1 - sense], p_imag[1 - sense], inner, sides, imag_time);

        // Last band
        inner = 1;
        sides = 1;
        process_band(tile_width, block_width, block_height, halo_x, block_start, tile_height - block_start, halo_y, tile_height - block_start - halo_y, a, b, external_pot_real, external_pot_imag, p_real[sense], p_imag[sense], p_real[1 - sense], p_imag[1 - sense], inner, sides, imag_time);
#endif /* _OPENMP */
    }
}

void HybridKernel::wait_for_completion(int iteration, int snapshots) {
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    //normalization for imaginary time evolution
    if(imag_time && ((iteration % 20) == 0 || ((snapshots > 0) && (iteration + 1) % snapshots == 0))) {
        CUDA_SAFE_CALL(cudaMemcpy2D(&(p_real[sense][gpu_start_y * tile_width + gpu_start_x]), tile_width * sizeof(double), pdev_real[sense], gpu_tile_width * sizeof(double), gpu_tile_width * sizeof(double), gpu_tile_height, cudaMemcpyDeviceToHost));
        CUDA_SAFE_CALL(cudaMemcpy2D(&(p_imag[sense][gpu_start_y * tile_width + gpu_start_x]), tile_width * sizeof(double), pdev_imag[sense], gpu_tile_width * sizeof(double), gpu_tile_width * sizeof(double), gpu_tile_height, cudaMemcpyDeviceToHost));

        int nProcs = 1;
#ifdef HAVE_MPI
        MPI_Comm_size(cartcomm, &nProcs);
#endif
        int height = tile_height - halo_y;
        int width = tile_width - halo_x;
        double sum = 0., sums[nProcs];
        for(int i = halo_y; i < height; i++) {
            for(int j = halo_x; j < width; j++) {
                sum += p_real[sense][j + i * tile_width] * p_real[sense][j + i * tile_width] + p_imag[sense][j + i * tile_width] * p_imag[sense][j + i * tile_width];
            }
        }
#ifdef HAVE_MPI
        MPI_Allgather(&sum, 1, MPI_DOUBLE, sums, 1, MPI_DOUBLE, cartcomm);
#else
        sums[1] = sum;
#endif
        double tot_sum = 0.;
        for(int i = 0; i < nProcs; i++)
            tot_sum += sums[i];
        double norm = sqrt(tot_sum);

        for(int i = 0; i < tile_height; i++) {
            for(int j = 0; j < tile_width; j++) {
                p_real[sense][j + i * tile_width] /= norm;
                p_imag[sense][j + i * tile_width] /= norm;
            }
        }
        CUDA_SAFE_CALL(cudaMemcpy2D(pdev_real[sense], gpu_tile_width * sizeof(double), &(p_real[sense][gpu_start_y * tile_width + gpu_start_x]), tile_width * sizeof(double), gpu_tile_width * sizeof(double), gpu_tile_height, cudaMemcpyHostToDevice));
        CUDA_SAFE_CALL(cudaMemcpy2D(pdev_imag[sense], gpu_tile_width * sizeof(double), &(p_imag[sense][gpu_start_y * tile_width + gpu_start_x]), tile_width * sizeof(double), gpu_tile_width * sizeof(double), gpu_tile_height, cudaMemcpyHostToDevice));
    }
}

void HybridKernel::get_sample(size_t dest_stride, size_t x, size_t y, size_t width, size_t height, double * dest_real, double * dest_imag) const {
    if ( (x != 0) || (y != 0) || (width != tile_width) || (height != tile_height)) {
        //printf("Only full tile samples are implementedaaa!\n");
        //return;
    }
    memcpy2D(dest_real, dest_stride * sizeof(double), &(p_real[sense][y * tile_width + x]), tile_width * sizeof(double), width * sizeof(double), height);
    memcpy2D(dest_imag, dest_stride * sizeof(double), &(p_imag[sense][y * tile_width + x]), tile_width * sizeof(double), width * sizeof(double), height);

    // Inner part

    CUDA_SAFE_CALL(cudaMemcpy2D(&(dest_real[(gpu_start_y + halo_y - y) * dest_stride + gpu_start_x + halo_x - x]), dest_stride * sizeof(double), &(pdev_real[sense][halo_y * gpu_tile_width + halo_x]), gpu_tile_width * sizeof(double), (gpu_tile_width - 2 * halo_x) * sizeof(double), gpu_tile_height - 2 * halo_y, cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy2D(&(dest_imag[(gpu_start_y + halo_y - y) * dest_stride + gpu_start_x + halo_x - x]), dest_stride * sizeof(double), &(pdev_imag[sense][halo_y * gpu_tile_width + halo_x]), gpu_tile_width * sizeof(double), (gpu_tile_width - 2 * halo_x) * sizeof(double), gpu_tile_height - 2 * halo_y, cudaMemcpyDeviceToHost));
}


void HybridKernel::start_halo_exchange() {
    // Halo exchange: LEFT/RIGHT
#ifdef HAVE_MPI
    int offset = (inner_start_y - start_y) * tile_width;
    MPI_Irecv(p_real[1 - sense] + offset, 1, verticalBorder, neighbors[LEFT], 1, cartcomm, req);
    MPI_Irecv(p_imag[1 - sense] + offset, 1, verticalBorder, neighbors[LEFT], 2, cartcomm, req + 1);
    offset = (inner_start_y - start_y) * tile_width + inner_end_x - start_x;
    MPI_Irecv(p_real[1 - sense] + offset, 1, verticalBorder, neighbors[RIGHT], 3, cartcomm, req + 2);
    MPI_Irecv(p_imag[1 - sense] + offset, 1, verticalBorder, neighbors[RIGHT], 4, cartcomm, req + 3);

    offset = (inner_start_y - start_y) * tile_width + inner_end_x - halo_x - start_x;
    MPI_Isend(p_real[1 - sense] + offset, 1, verticalBorder, neighbors[RIGHT], 1, cartcomm, req + 4);
    MPI_Isend(p_imag[1 - sense] + offset, 1, verticalBorder, neighbors[RIGHT], 2, cartcomm, req + 5);
    offset = (inner_start_y - start_y) * tile_width + halo_x;
    MPI_Isend(p_real[1 - sense] + offset, 1, verticalBorder, neighbors[LEFT], 3, cartcomm, req + 6);
    MPI_Isend(p_imag[1 - sense] + offset, 1, verticalBorder, neighbors[LEFT], 4, cartcomm, req + 7);
#else
    if(periods[1] != 0) {
        int offset = (inner_start_y - start_y) * tile_width;
        memcpy2D(&(p_real[1 - sense][offset]), tile_width * sizeof(double), &(p_real[1 - sense][offset + tile_width - 2 * halo_x]), tile_width * sizeof(double), halo_x * sizeof(double), tile_height - 2 * halo_y);
        memcpy2D(&(p_imag[1 - sense][offset]), tile_width * sizeof(double), &(p_imag[1 - sense][offset + tile_width - 2 * halo_x]), tile_width * sizeof(double), halo_x * sizeof(double), tile_height - 2 * halo_y);
        memcpy2D(&(p_real[1 - sense][offset + tile_width - halo_x]), tile_width * sizeof(double), &(p_real[1 - sense][offset + halo_x]), tile_width * sizeof(double), halo_x * sizeof(double), tile_height - 2 * halo_y);
        memcpy2D(&(p_imag[1 - sense][offset + tile_width - halo_x]), tile_width * sizeof(double), &(p_imag[1 - sense][offset + halo_x]), tile_width * sizeof(double), halo_x * sizeof(double), tile_height - 2 * halo_y);
    }
#endif
}

void HybridKernel::finish_halo_exchange() {
#ifdef HAVE_MPI
    MPI_Waitall(8, req, statuses);

    // Halo exchange: UP/DOWN
    int offset = 0;
    MPI_Irecv(p_real[sense] + offset, 1, horizontalBorder, neighbors[UP], 1, cartcomm, req);
    MPI_Irecv(p_imag[sense] + offset, 1, horizontalBorder, neighbors[UP], 2, cartcomm, req + 1);
    offset = (inner_end_y - start_y) * tile_width;
    MPI_Irecv(p_real[sense] + offset, 1, horizontalBorder, neighbors[DOWN], 3, cartcomm, req + 2);
    MPI_Irecv(p_imag[sense] + offset, 1, horizontalBorder, neighbors[DOWN], 4, cartcomm, req + 3);

    offset = (inner_end_y - halo_y - start_y) * tile_width;
    MPI_Isend(p_real[sense] + offset, 1, horizontalBorder, neighbors[DOWN], 1, cartcomm, req + 4);
    MPI_Isend(p_imag[sense] + offset, 1, horizontalBorder, neighbors[DOWN], 2, cartcomm, req + 5);
    offset = halo_y * tile_width;
    MPI_Isend(p_real[sense] + offset, 1, horizontalBorder, neighbors[UP], 3, cartcomm, req + 6);
    MPI_Isend(p_imag[sense] + offset, 1, horizontalBorder, neighbors[UP], 4, cartcomm, req + 7);
#else
    if(periods[0] != 0) {
        int offset = (inner_end_y - start_y) * tile_width;
        memcpy2D(p_real[sense], tile_width * sizeof(double), &(p_real[sense][offset - halo_y * tile_width]), tile_width * sizeof(double), tile_width * sizeof(double), halo_y);
        memcpy2D(p_imag[sense], tile_width * sizeof(double), &(p_imag[sense][offset - halo_y * tile_width]), tile_width * sizeof(double), tile_width * sizeof(double), halo_y);
        memcpy2D(&(p_real[sense][offset]), tile_width * sizeof(double), &(p_real[sense][halo_y * tile_width]), tile_width * sizeof(double), tile_width * sizeof(double), halo_y);
        memcpy2D(&(p_imag[sense][offset]), tile_width * sizeof(double), &(p_imag[sense][halo_y * tile_width]), tile_width * sizeof(double), tile_width * sizeof(double), halo_y);
    }
#endif
    // Exhange internal halos

    // Copy the internal halos to the GPU memory

    // Vertical
    size_t height = gpu_tile_height - 2 * halo_y;	// The vertical halo in rows
    size_t width = halo_x;	// The number of columns of the matrix

    // Left
    size_t offset_x = gpu_start_x; // block_width-2*halo_x;
    size_t offset_y = gpu_start_y + halo_y; // block_height-halo_y;
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(pdev_real[sense][halo_y * gpu_tile_width]), gpu_tile_width * sizeof(double), &(p_real[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyHostToDevice, stream));
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(pdev_imag[sense][halo_y * gpu_tile_width]), gpu_tile_width * sizeof(double), &(p_imag[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyHostToDevice, stream));

    // Right
    offset_x = gpu_start_x + gpu_tile_width - halo_x; // tile_width-last_block_width+halo_x;
    offset_y = gpu_start_y + halo_y; // block_height-halo_y;
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(pdev_real[sense][halo_y * gpu_tile_width + gpu_tile_width - halo_x]), gpu_tile_width * sizeof(double), &(p_real[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyHostToDevice, stream));
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(pdev_imag[sense][halo_y * gpu_tile_width + gpu_tile_width - halo_x]), gpu_tile_width * sizeof(double), &(p_imag[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyHostToDevice, stream));


    // Horizontal
    height = halo_y;
    width = gpu_tile_width; //tile_width-block_width-last_block_width+4*halo_x;

    // Top
    offset_x = gpu_start_x; //block_width-2*halo_x;
    offset_y = gpu_start_y; //block_height-2*halo_y;
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(pdev_real[sense][0]), gpu_tile_width * sizeof(double), &(p_real[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyHostToDevice, stream));
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(pdev_imag[sense][0]), gpu_tile_width * sizeof(double), &(p_imag[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyHostToDevice, stream));


    // Bottom
    offset_x = gpu_start_x; // block_width-2*halo_x;
    offset_y = gpu_start_y + gpu_tile_height - halo_y; //tile_height-last_block_height+halo_y;
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(pdev_real[sense][(gpu_tile_height - halo_y)*gpu_tile_width]), gpu_tile_width * sizeof(double), &(p_real[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyHostToDevice, stream));
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(pdev_imag[sense][(gpu_tile_height - halo_y)*gpu_tile_width]), gpu_tile_width * sizeof(double), &(p_imag[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyHostToDevice, stream));

    // Copy the internal halos to the CPU memory

    // Vertical
    height = gpu_tile_height - 4 * halo_y; // tile_height-block_height-last_block_height;
    width = halo_x;

    // Left
    offset_x = gpu_start_x + halo_x; //block_width-halo_x;
    offset_y = gpu_start_y + 2 * halo_y; //block_height;
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(p_real[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), &(pdev_real[sense][(2 * halo_y)*gpu_tile_width + halo_x]), gpu_tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyDeviceToHost, stream));
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(p_imag[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), &(pdev_imag[sense][(2 * halo_y)*gpu_tile_width + halo_x]), gpu_tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyDeviceToHost, stream));

    // Right
    offset_x = gpu_start_x + gpu_tile_width - 2 * halo_x; //tile_width-last_block_width;
    offset_y = gpu_start_y + 2 * halo_y; //block_height;
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(p_real[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), &(pdev_real[sense][(2 * halo_y)*gpu_tile_width + gpu_tile_width - 2 * halo_x]), gpu_tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyDeviceToHost, stream));
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(p_imag[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), &(pdev_imag[sense][(2 * halo_y)*gpu_tile_width + gpu_tile_width - 2 * halo_x]), gpu_tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyDeviceToHost, stream));

    // Horizontal
    height = halo_y;
    width = gpu_tile_width - 2 * halo_x; //tile_width-block_width-last_block_width+2*halo_x;

    // Top
    offset_x = gpu_start_x + halo_x; // block_width-halo_x;
    offset_y = gpu_start_y + halo_y; // block_height-halo_y;
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(p_real[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), &(pdev_real[sense][halo_y * gpu_tile_width + halo_x]), gpu_tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyDeviceToHost, stream));
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(p_imag[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), &(pdev_imag[sense][halo_y * gpu_tile_width + halo_x]), gpu_tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyDeviceToHost, stream));

    // Bottom
    offset_x = gpu_start_x + halo_x; // block_width-halo_x;
    offset_y = gpu_start_y + gpu_tile_height - 2 * halo_y; //tile_height-last_block_height;
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(p_real[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), &(pdev_real[sense][(gpu_tile_height - 2 * halo_y)*gpu_tile_width + halo_x]), gpu_tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyDeviceToHost, stream));
    CUDA_SAFE_CALL(cudaMemcpy2DAsync(&(p_imag[sense][offset_y * tile_width + offset_x]), tile_width * sizeof(double), &(pdev_imag[sense][(gpu_tile_height - 2 * halo_y)*gpu_tile_width + halo_x]), gpu_tile_width * sizeof(double), width * sizeof(double), height, cudaMemcpyDeviceToHost, stream));

#ifdef HAVE_MPI
    MPI_Waitall(8, req, statuses);
#endif
}
