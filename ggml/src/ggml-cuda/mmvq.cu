#include "mmvq.cuh"
#include "vecdotq.cuh"

typedef float (*vec_dot_q_cuda_t)(const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs);

static constexpr __device__ vec_dot_q_cuda_t get_vec_dot_q_cuda(ggml_type type) {
    return type == GGML_TYPE_Q4_0 ? vec_dot_q4_0_q8_1 :
        type == GGML_TYPE_Q4_1 ? vec_dot_q4_1_q8_1 :
        type == GGML_TYPE_Q5_0 ? vec_dot_q5_0_q8_1 :
        type == GGML_TYPE_Q5_1 ? vec_dot_q5_1_q8_1 :
        type == GGML_TYPE_Q8_0 ? vec_dot_q8_0_q8_1 :
        type == GGML_TYPE_Q2_K ? vec_dot_q2_K_q8_1 :
        type == GGML_TYPE_Q3_K ? vec_dot_q3_K_q8_1 :
        type == GGML_TYPE_Q4_K ? vec_dot_q4_K_q8_1 :
        type == GGML_TYPE_Q5_K ? vec_dot_q5_K_q8_1 :
        type == GGML_TYPE_Q6_K ? vec_dot_q6_K_q8_1 :
        type == GGML_TYPE_IQ2_XXS ? vec_dot_iq2_xxs_q8_1 :
        type == GGML_TYPE_IQ2_XS ? vec_dot_iq2_xs_q8_1 :
        type == GGML_TYPE_IQ2_S ? vec_dot_iq2_s_q8_1 :
        type == GGML_TYPE_IQ3_XXS ? vec_dot_iq3_xxs_q8_1 :
        type == GGML_TYPE_IQ1_S ? vec_dot_iq1_s_q8_1 :
        type == GGML_TYPE_IQ1_M ? vec_dot_iq1_m_q8_1 :
        type == GGML_TYPE_IQ4_NL ? vec_dot_iq4_nl_q8_1 :
        type == GGML_TYPE_IQ4_XS ? vec_dot_iq4_xs_q8_1 :
        type == GGML_TYPE_IQ3_S ? vec_dot_iq3_s_q8_1 :
        nullptr;
}

static constexpr __device__ int get_vdr_mmvq(ggml_type type) {
    return type == GGML_TYPE_Q4_0 ? VDR_Q4_0_Q8_1_MMVQ :
        type == GGML_TYPE_Q4_1    ? VDR_Q4_1_Q8_1_MMVQ :
        type == GGML_TYPE_Q5_0    ? VDR_Q5_0_Q8_1_MMVQ :
        type == GGML_TYPE_Q5_1    ? VDR_Q5_1_Q8_1_MMVQ :
        type == GGML_TYPE_Q8_0    ? VDR_Q8_0_Q8_1_MMVQ :
        type == GGML_TYPE_Q2_K    ? VDR_Q2_K_Q8_1_MMVQ :
        type == GGML_TYPE_Q3_K    ? VDR_Q3_K_Q8_1_MMVQ :
        type == GGML_TYPE_Q4_K    ? VDR_Q4_K_Q8_1_MMVQ :
        type == GGML_TYPE_Q5_K    ? VDR_Q5_K_Q8_1_MMVQ :
        type == GGML_TYPE_Q6_K    ? VDR_Q6_K_Q8_1_MMVQ :
        type == GGML_TYPE_IQ2_XXS ? VDR_IQ2_XXS_Q8_1_MMVQ :
        type == GGML_TYPE_IQ2_XS  ? VDR_IQ2_XS_Q8_1_MMVQ :
        type == GGML_TYPE_IQ2_S   ? VDR_IQ2_S_Q8_1_MMVQ :
        type == GGML_TYPE_IQ3_XXS ? VDR_IQ3_XXS_Q8_1_MMVQ :
        type == GGML_TYPE_IQ3_S   ? VDR_IQ3_S_Q8_1_MMVQ :
        type == GGML_TYPE_IQ4_NL  ? VDR_IQ4_NL_Q8_1_MMVQ :
        type == GGML_TYPE_IQ4_XS  ? VDR_IQ4_XS_Q8_1_MMVQ :
        1;
}

enum mmvq_parameter_table_id {
    MMVQ_PARAMETERS_GENERIC = 0,
    MMVQ_PARAMETERS_GCN,
    MMVQ_PARAMETERS_RDNA2
};

static constexpr __device__ mmvq_parameter_table_id get_device_table_id() {
#if defined(RDNA2) || defined(RDNA3) || defined(RDNA4)
    return MMVQ_PARAMETERS_RDNA2;
#elif defined(GCN) || defined(CDNA)
    return MMVQ_PARAMETERS_GCN;
#else
    return MMVQ_PARAMETERS_GENERIC;
#endif
}

static __host__ mmvq_parameter_table_id get_device_table_id(int cc) {
    if (GGML_CUDA_CC_IS_RDNA2(cc) || GGML_CUDA_CC_IS_RDNA3(cc) || GGML_CUDA_CC_IS_RDNA4(cc)) {
        return MMVQ_PARAMETERS_RDNA2;
    }
    if (GGML_CUDA_CC_IS_GCN(cc) || GGML_CUDA_CC_IS_CDNA(cc)) {
        return MMVQ_PARAMETERS_GCN;
    }
    return MMVQ_PARAMETERS_GENERIC;
}

static constexpr __host__ __device__ int calc_nwarps(int ncols_y,  mmvq_parameter_table_id table_id) {
    if (table_id == MMVQ_PARAMETERS_GENERIC) {
        switch (ncols_y) {
            case 1:
            case 2:
            case 3:
            case 4:
                return 4;
            case 5:
            case 6:
            case 7:
            case 8:
                return 2;
            default:
                return 1;
        }
    } else if (table_id == MMVQ_PARAMETERS_GCN) {
        switch (ncols_y) {
            case 1:
            case 2:
            case 3:
            case 4:
                return 2;
            case 5:
            case 6:
            case 7:
            case 8:
            default:
                return 1;
        }
    }
    return 1;
}

static constexpr __host__ __device__ int calc_rows_per_block(int ncols_y, int table_id) {
    if (table_id == MMVQ_PARAMETERS_GENERIC || table_id == MMVQ_PARAMETERS_GCN) {
        switch (ncols_y) {
            case 1:
                return 1;
            case 2:
            case 3:
            case 4:
            case 5:
            case 6:
            case 7:
            case 8:
                return 2;
            default:
                return 1;
        }
    }
    return 1;
}

template <ggml_type type, int ncols_y>
// tell the compiler to use as many registers as it wants, see nwarps definition below
__launch_bounds__(calc_nwarps(ncols_y, get_device_table_id())*ggml_cuda_get_physical_warp_size(), 1)
static __global__ void mul_mat_vec_q(
    const void * __restrict__ vx, const void * __restrict__ vy, float * __restrict__ dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int nrows_dst) {

    constexpr int qk  = ggml_cuda_type_traits<type>::qk;
    constexpr int qi  = ggml_cuda_type_traits<type>::qi;
    constexpr int vdr = get_vdr_mmvq(type);
    constexpr mmvq_parameter_table_id table_id = get_device_table_id();
    constexpr int nwarps = calc_nwarps(ncols_y, table_id);
    constexpr int rows_per_cuda_block = calc_rows_per_block(ncols_y, table_id);
    constexpr int warp_size = ggml_cuda_get_physical_warp_size();

    constexpr vec_dot_q_cuda_t vec_dot_q_cuda = get_vec_dot_q_cuda(type);

    const     int tid = warp_size*threadIdx.y + threadIdx.x;
    const     int row0 = rows_per_cuda_block*blockIdx.x;
    const     int blocks_per_row_x = ncols_x / qk;
    const     int blocks_per_col_y = nrows_y / QK8_1;
    constexpr int blocks_per_iter = vdr * nwarps*warp_size / qi;

    // partial sum for each thread
    float tmp[ncols_y][rows_per_cuda_block] = {{0.0f}};

    const block_q8_1 * y = (const block_q8_1 *) vy;

    for (int kbx = tid / (qi/vdr); kbx < blocks_per_row_x; kbx += blocks_per_iter) {
        const int kby = kbx * (qk/QK8_1); // y block index that aligns with kbx

        // x block quant index when casting the quants to int
        const int kqs = vdr * (tid % (qi/vdr));

#pragma unroll
        for (int j = 0; j < ncols_y; ++j) {
#pragma unroll
            for (int i = 0; i < rows_per_cuda_block; ++i) {
                tmp[j][i] += vec_dot_q_cuda(vx, &y[j*blocks_per_col_y + kby], (row0 + i)*blocks_per_row_x + kbx, kqs);
            }
        }
    }

    __shared__ float tmp_shared[nwarps-1 > 0 ? nwarps-1 : 1][ncols_y][rows_per_cuda_block][warp_size];
    if (threadIdx.y > 0) {
#pragma unroll
        for (int j = 0; j < ncols_y; ++j) {
#pragma unroll
            for (int i = 0; i < rows_per_cuda_block; ++i) {
                tmp_shared[threadIdx.y-1][j][i][threadIdx.x] = tmp[j][i];
            }
        }
    }
    __syncthreads();
    if (threadIdx.y > 0) {
        return;
    }

    // sum up partial sums and write back result
#pragma unroll
    for (int j = 0; j < ncols_y; ++j) {
#pragma unroll
        for (int i = 0; i < rows_per_cuda_block; ++i) {
#pragma unroll
            for (int l = 0; l < nwarps-1; ++l) {
                tmp[j][i] += tmp_shared[l][j][i][threadIdx.x];
            }
            tmp[j][i] = warp_reduce_sum<warp_size>(tmp[j][i]);
        }

        if (threadIdx.x < rows_per_cuda_block && (rows_per_cuda_block == 1 || row0 + threadIdx.x < (unsigned)nrows_dst)) {
            dst[j*nrows_dst + row0 + threadIdx.x] = tmp[j][threadIdx.x];
        }
    }

    GGML_UNUSED(nrows_x);
}

static std::pair<dim3, dim3> calc_launch_params(const int ncols_y, const int nrows_x, const int warp_size, const mmvq_parameter_table_id table_id) {
    const int64_t nblocks = (nrows_x + calc_rows_per_block(ncols_y, table_id) - 1) / calc_rows_per_block(ncols_y, table_id);
    const dim3 block_nums(nblocks, 1, 1);
    const dim3 block_dims(warp_size, calc_nwarps(ncols_y, table_id), 1);
    return {block_nums, block_dims};
}

template <ggml_type type>
static void mul_mat_vec_q_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    GGML_ASSERT(ncols_x % ggml_blck_size(type) == 0);
    GGML_ASSERT(ncols_y <= MMVQ_MAX_BATCH_SIZE);

    const int device = ggml_cuda_get_device();
    const int warp_size = ggml_cuda_info().devices[device].warp_size;
    const mmvq_parameter_table_id table_id = get_device_table_id(ggml_cuda_info().devices[device].cc);

    switch (ncols_y) {
        case 1:
        {
            constexpr int c_ncols_y = 1;
            std::pair<dim3, dim3> dims = calc_launch_params(c_ncols_y, nrows_x, warp_size, table_id);
            mul_mat_vec_q<type, c_ncols_y><<<dims.first, dims.second, 0, stream>>>(vx, vy, dst, ncols_x, nrows_x, nrows_y, nrows_dst);
            break;
        }
        case 2:
        {
            constexpr int c_ncols_y = 2;
            std::pair<dim3, dim3> dims = calc_launch_params(c_ncols_y, nrows_x, warp_size, table_id);
            mul_mat_vec_q<type, c_ncols_y><<<dims.first, dims.second, 0, stream>>>(vx, vy, dst, ncols_x, nrows_x, nrows_y, nrows_dst);
            break;
        }
        case 3:
        {
            constexpr int c_ncols_y = 3;
            std::pair<dim3, dim3> dims = calc_launch_params(c_ncols_y, nrows_x, warp_size, table_id);
            mul_mat_vec_q<type, c_ncols_y><<<dims.first, dims.second, 0, stream>>>(vx, vy, dst, ncols_x, nrows_x, nrows_y, nrows_dst);
            break;
        }
        case 4:
        {
            constexpr int c_ncols_y = 4;
            std::pair<dim3, dim3> dims = calc_launch_params(c_ncols_y, nrows_x, warp_size, table_id);
            mul_mat_vec_q<type, c_ncols_y><<<dims.first, dims.second, 0, stream>>>(vx, vy, dst, ncols_x, nrows_x, nrows_y, nrows_dst);
            break;
        }
        case 5:
        {
            constexpr int c_ncols_y = 5;
            std::pair<dim3, dim3> dims = calc_launch_params(c_ncols_y, nrows_x, warp_size, table_id);
            mul_mat_vec_q<type, c_ncols_y><<<dims.first, dims.second, 0, stream>>>(vx, vy, dst, ncols_x, nrows_x, nrows_y, nrows_dst);
            break;
        }
        case 6:
        {
            constexpr int c_ncols_y = 6;
            std::pair<dim3, dim3> dims = calc_launch_params(c_ncols_y, nrows_x, warp_size, table_id);
            mul_mat_vec_q<type, c_ncols_y><<<dims.first, dims.second, 0, stream>>>(vx, vy, dst, ncols_x, nrows_x, nrows_y, nrows_dst);
            break;
        }
        case 7:
        {
            constexpr int c_ncols_y = 7;
            std::pair<dim3, dim3> dims = calc_launch_params(c_ncols_y, nrows_x, warp_size, table_id);
            mul_mat_vec_q<type, c_ncols_y><<<dims.first, dims.second, 0, stream>>>(vx, vy, dst, ncols_x, nrows_x, nrows_y, nrows_dst);
            break;
        }
        case 8:
        {
            constexpr int c_ncols_y = 8;
            std::pair<dim3, dim3> dims = calc_launch_params(c_ncols_y, nrows_x, warp_size, table_id);
            mul_mat_vec_q<type, c_ncols_y><<<dims.first, dims.second, 0, stream>>>(vx, vy, dst, ncols_x, nrows_x, nrows_y, nrows_dst);
            break;
        }
        default:
            GGML_ABORT("fatal error");
            break;
    }
}

static void mul_mat_vec_q4_0_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_Q4_0>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_q4_1_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_Q4_1>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_q5_0_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_Q5_0>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_q5_1_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_Q5_1>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_q8_0_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_Q8_0>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_q2_K_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_Q2_K>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_q3_K_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_Q3_K>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_q4_K_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_Q4_K>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_q5_K_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_Q5_K>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_q6_K_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_Q6_K>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_iq2_xxs_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_IQ2_XXS>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_iq2_xs_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_IQ2_XS>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_iq2_s_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_IQ2_S>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_iq3_xxs_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_IQ3_XXS>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_iq1_s_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_IQ1_S>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_iq1_m_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_IQ1_M>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_iq4_nl_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_IQ4_NL>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_iq4_xs_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_IQ4_XS>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

static void mul_mat_vec_iq3_s_q8_1_cuda(
    const void * vx, const void * vy, float * dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst, cudaStream_t stream) {

    mul_mat_vec_q_cuda<GGML_TYPE_IQ3_S>(vx, vy, dst, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, stream);
}

void ggml_cuda_op_mul_mat_vec_q(
    ggml_backend_cuda_context & ctx,
    const ggml_tensor * src0, const ggml_tensor * src1, ggml_tensor * dst, const char * src0_dd_i, const float * src1_ddf_i,
    const char * src1_ddq_i, float * dst_dd_i, const int64_t row_low, const int64_t row_high, const int64_t src1_ncols,
    const int64_t src1_padded_row_size, cudaStream_t stream) {

    const int64_t ne00 = src0->ne[0];
    const int64_t row_diff = row_high - row_low;

    const int64_t ne10 = src1->ne[0];
    GGML_ASSERT(ne10 % QK8_1 == 0);

    const int64_t ne0 = dst->ne[0];

    int id = ggml_cuda_get_device();

    // the main device has a larger memory buffer to hold the results from all GPUs
    // nrows_dst == nrows of the matrix that the kernel writes into
    const int64_t nrows_dst = id == ctx.device ? ne0 : row_diff;

    switch (src0->type) {
        case GGML_TYPE_Q4_0:
            mul_mat_vec_q4_0_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_Q4_1:
            mul_mat_vec_q4_1_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_Q5_0:
            mul_mat_vec_q5_0_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_Q5_1:
            mul_mat_vec_q5_1_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_Q8_0:
            mul_mat_vec_q8_0_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_Q2_K:
            mul_mat_vec_q2_K_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_Q3_K:
            mul_mat_vec_q3_K_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_Q4_K:
            mul_mat_vec_q4_K_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_Q5_K:
            mul_mat_vec_q5_K_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_Q6_K:
            mul_mat_vec_q6_K_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_IQ2_XXS:
            mul_mat_vec_iq2_xxs_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_IQ2_XS:
            mul_mat_vec_iq2_xs_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_IQ2_S:
            mul_mat_vec_iq2_s_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_IQ3_XXS:
            mul_mat_vec_iq3_xxs_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_IQ1_S:
            mul_mat_vec_iq1_s_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_IQ1_M:
            mul_mat_vec_iq1_m_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_IQ4_NL:
            mul_mat_vec_iq4_nl_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_IQ4_XS:
            mul_mat_vec_iq4_xs_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        case GGML_TYPE_IQ3_S:
            mul_mat_vec_iq3_s_q8_1_cuda(src0_dd_i, src1_ddq_i, dst_dd_i, ne00, row_diff, src1_padded_row_size, src1_ncols, nrows_dst, stream);
            break;
        default:
            GGML_ABORT("fatal error");
            break;
    }

    GGML_UNUSED(src1);
    GGML_UNUSED(dst);
    GGML_UNUSED(src1_ddf_i);
    GGML_UNUSED(src1_ncols);
    GGML_UNUSED(src1_padded_row_size);
}
