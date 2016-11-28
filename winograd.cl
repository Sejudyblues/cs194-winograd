#define block_size 8

/* Computes G . filter . G^T for every filter in filters.
 * Write the output into U, which has not been scattered yet. */
__kernel void filter_transform(__global float *filters,
        __global float *G, // TODO: put G in local memory
        __global float *U,
        int K,
        int C,
        int r,
        int alpha)
{

  size_t k = get_global_id(0);
  size_t c = get_global_id(1);

  if((int) k < K && (int) c < C) {
    int offset = (k * C + c) * r * r; // increasing multiples of 9

    // temp = G * filters[k][c]
    float temp[12];
    float sum;
    for(int i = 0; i < alpha; i++) {
      for(int j = 0; j < r; j++) {
        sum = 0;
        for(int l = 0; l < r; l ++) {
          sum += G[i*r + l] * filters[offset + l*r + j];
        }
        temp[i*r + j] = sum;
      }
    }

    // U[k][c] = temp * G^T
    offset = (k * C + c) * alpha * alpha;
    for(int i = 0; i < alpha; i++){
      for(int j = 0; j < alpha; j++) {
        sum = 0;
        for(int l = 0; l < r; l++) {
          sum += temp[i*r + l] * G[j*r + l];
        }
        // U[offset + i*alpha + j] = sum;
        U[i*(alpha*K*C) + j*(K*C) + k*C + c] = sum;
      }
    }

    // for(int xi = 0; xi < alpha; xi++) {
    //   for(int nu = 0; nu < alpha; nu++) {
    //     U[xi*(alpha*K*C) + nu*(K*C) + k*C + c] = temp_u[xi*alpha + nu];
    //   }
    // }

    // for xi in range(alpha):
    //         for nu in range(alpha):
    //             U[xi][nu][k][c] = u[xi][nu]
  }
}

/* Given an array that is of shape (d1, d2, d3, d4), scatters 
 * the array so that it has shape (d3, d4, d1, d2). */
__kernel void scatter(__global float *in,
        __global float *out,
        int d1,
        int d2,
        int d3,
        int d4)
{
  size_t i = get_global_id(0); // TODO: switch to int
  size_t j = get_global_id(1);
  if ((int) i < d3 && (int) j < d4) {
    for(int k = 0; k < d1; k++) {
      for(int l = 0; l < d2; l++) {
        out[i*(d4*d1*d2) + j*(d1*d2) + k*d2 + l] = in[k*(d2*d3*d4) + l*(d3*d4)+ i*d4 +j];
      }
    }
  }
}

__kernel void data_transform(__global float *data,
        __global float *B, // TODO: put B in local memory
        __global float *V,
        int C,
        int P,
        int H,
        int W,
        int m,
        int alpha)
{
  int c = get_global_id(0);
  int block_y = get_global_id(1);
  int block_x = get_global_id(2);
  int b = block_y * get_global_size(2) + block_x; // TODO: change get_global_size(2) to num_w_tiles

  if ((int) c < C && (int) b < P) {

    int x = block_x * m;
    int y = block_y * m;

    float temp[16];
    float sum;
    for(int i = 0; i < alpha; i++) {
      for(int j = 0; j < alpha; j++) {
        sum = 0;
        for(int l = 0; l < alpha; l++) {
          sum += B[l*alpha + i] * data[c*(H*W) + (y+l)*W + (x+j)];
        }
        temp[i*alpha + j] = sum;
      }
    }

    // int offset = c*(P*alpha*alpha) + b*(alpha*alpha);
    for(int i = 0; i < alpha; i++) {
      for(int j = 0; j < alpha; j++) {
        sum = 0;
        for(int l = 0; l < alpha; l++) {
          sum += temp[i*alpha + l] * B[l*alpha + j];
        }
        V[i*(alpha*C*P) + j*(C*P) + c*P + b] = sum;
      }
    }

  }
}

__kernel void calc_M (__global float *U,
        __global float *V, // should store transpose of V so it's faster
        __global float *M,
        int K,
        int P,
        int C,
        int alpha,
        __local float *U_local,
        __local float *V_local)
{
  int k = get_global_id(0);
  int b = get_global_id(1);
  if (k < K && b < P) {

    // U local is C by C and V local is C by C // only works if C is small
    float value;
    for(int xi = 0; xi < alpha; xi++) {
      for(int nu = 0; nu < alpha; nu++) {

        int kloc = get_local_id(0);
        int bloc = get_local_id(1);
        // EACH THREAD SHOULD JUST READ ONE ELEMENT
        U_local[kloc*C + bloc] = U[xi*(alpha*K*C) + nu*(K*C) + k*C + bloc];
        V_local[kloc*C + bloc] = V[xi*(alpha*C*P) + nu*(C*P) + kloc*P + b];

        // probably want to transpose U local
        barrier(CLK_LOCAL_MEM_FENCE);

        value = 0;
        #pragma unroll
        for(int iloc = 0; iloc < C; iloc++) {
          value += U_local[kloc*C + iloc] * V_local[iloc*C + bloc];
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        M[xi*(alpha*K*P) + nu*(K*P) + k*P + b] = value;
      }
    }
  }
}

__kernel void calc_Y(__global float *M,
        __global float *A,
        __global float *Y,
        int out_H,
        int out_W,
        int K,
        int P,
        int m,
        int alpha,
        int num_w_tiles)
{
  int k = get_global_id(0);
  int block_y = get_global_id(1);
  int block_x = get_global_id(2);

  int b = block_y * num_w_tiles + block_x;

  if (k < K && b < P) {
    float temp_m[16]; // alpha x alpha
    // gather
    for(int xi = 0; xi < alpha; xi++) {
      for(int nu = 0; nu < alpha; nu++) {
        temp_m[xi*alpha + nu] = M[xi*(alpha*K*P) + nu*(K*P)+ k*P + b]; //M[xi][nu][k][b]
      }
    }
    // A is alpha x m
    float temp[8];
    float sum;
    for(int i = 0; i < m; i++) {
      for(int j = 0; j < alpha; j ++) {
        sum = 0;
        for(int l = 0; l < alpha; l++) {
          sum += A[l*m + i] * temp_m[l*alpha + j];
        }
        temp[i*alpha + j] = sum;
      }
    }

    int x = block_x * m;
    int y = block_y * m;

    for(int i = 0; i < m; i++) {
      for(int j = 0; j < m; j ++) {
        sum = 0;
        for(int l = 0; l < alpha; l++) {
          sum += temp[i*alpha + l] * A[l*m + j];
        }
        Y[k*(out_H*out_W) + (y+i)*out_W + (x+j)] = sum;
      }
    }
  }
}
