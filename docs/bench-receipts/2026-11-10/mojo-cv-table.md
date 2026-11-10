# 2D speed rows: mojo-cv vs cv2 5.0

Method: `tests/run.sh --bench-all --md docs/bench.md`. Each row runs the same op in one resident process with `reps=5`
and keeps the best wall time of the compute only (file load and save excluded), ours via `.bin/mojo-cv`, cv2 via
`tools/oracle_cv2.py` (numpy in, cv2 call, best of 5). Both sides use all threads of the 7800X3D; CPU only, no GPU.
Inputs are the same `.mcv` fixtures (`hd*` = 1920x1080 synthetic scenes from `scene()` in `tools/oracle_cv2.py`, the rest
smaller). Target: ours <= cv2. **Misses are listed as measured; nothing is hidden.** The HOG rows time cv2 4.8.1
(cv2 5.0 has no HOG).

1080p rows: 47 of 63 faster than cv2, 4 more within 1.5x, the rest slower (ratio column).

Slower than cv2 in this run: canny_hdg, cvt_hsv_hd, cvt_lab_hd, cvt_luv_hd, cvt_swap_hd, flip_x_hd, gmm_hdg, gmm_hdg_big, rim_hdg, thresh_bin_hdg, tophat_hdg, transpose_hd.

- **Parallel dispatch**: `max.algorithm.parallelize` with the default 16 workers costs about 215 us per region (best of
  50 trivial regions); with 8 workers (the physical cores) it costs about 8 us, so `core.par` uses 8 and takes 16 only for
  regions that run for milliseconds. Allocating and zero-filling a 2 MB `Mat` is 18 us.
- **Read the ratios with care.** One run of this table is one sample on a shared desktop: a row near 1.0 can land on either
  side, and a loaded run of the same binary moves a row by up to a factor of two. `tools/abbench.py OLD_BIN` runs an old
  build, the current build and cv2 back to back per row, which is the fair comparison when the machine is not quiet.
- Point-set ops (projectPoints, estimateAffine2D, stereoRectify) take microseconds on both sides; 0.00 ms entries are
  below the timer's resolution, not a result.

## 1920x1080 rows

| op | row | ours ms | cv2 ms | ours/cv2 |
|---|---|---:|---:|---:|
| flip | flip_x_hd | 0.36 | 0.14 | 2.60 |
| rotate | rotate_cw_hd | 1.02 | 1.18 | 0.86 **faster** |
| transpose | transpose_hd | 0.18 | 0.11 | 1.66 |
| absdiff | absdiff_hd | 0.10 | 0.26 | 0.39 **faster** |
| bitwise_and | bitwise_and_hd | 0.11 | 0.25 | 0.43 **faster** |
| bitwise_not | bitwise_not_hd | 0.11 | 0.17 | 0.64 **faster** |
| convert | convert_u8_f32_hd | 0.33 | 12.30 | 0.03 **faster** |
| bitwise_or | bitwise_or_hd | 0.11 | 0.22 | 0.51 **faster** |
| bitwise_xor | bitwise_xor_hd | 0.12 | 0.22 | 0.56 **faster** |
| ORB | orb_hd | 11.49 | 14.06 | 0.82 **faster** |
| granulometry | gran_hdg | 9.54 | 7.26 | 1.31 |
| glcm | glcm_hdg_diag | 8.61 | 81.16 | 0.11 **faster** |
| lbpHist | lbp_hdg | 3.82 | 34.43 | 0.11 **faster** |
| resizeMmpx | rmm_down_hdg | 0.12 | 2.02 | 0.06 **faster** |
| granulometryMm | gmm_hdg | 51.14 | 16.51 | 3.10 |
| tophat | tophat_hdg | 3.40 | 1.86 | 1.83 |
| smoothFraction | smooth_hdg | 2.55 | 6.59 | 0.39 **faster** |
| sharpMap | sharp_hdg | 5.65 | 3.79 | 1.49 |
| autocorr | acorr_hdg | 16.43 | 71.16 | 0.23 **faster** |
| waveletEnergy | wav_hdg | 7.79 | 7.83 | 1.00 **faster** |
| trayRim | rim_hdg | 4.94 | 1.33 | 3.72 |
| granulometryMm | gmm_hdg_big | 25.85 | 11.49 | 2.25 |
| GaussianBlur | gauss5_hd | 0.13 | 0.36 | 0.35 **faster** |
| GaussianBlur | gauss_s2_hdg | 0.38 | 0.86 | 0.44 **faster** |
| pyrDown | pyrdown_hd | 0.06 | 1.09 | 0.05 **faster** |
| pyrDown | pyrdown_hdg | 0.04 | 0.30 | 0.12 **faster** |
| Sobel | sobel_dx_hdg | 0.11 | 0.48 | 0.23 **faster** |
| Sobel | sobel_dy5_hd | 0.41 | 1.18 | 0.35 **faster** |
| threshold | thresh_bin_hdg | 0.04 | 0.02 | 2.13 |
| threshold | thresh_tozinv_hd | 0.10 | 0.16 | 0.64 **faster** |
| threshold | thresh_otsu_hdg | 0.05 | 1.16 | 0.04 **faster** |
| threshold | thresh_tri_hdg | 0.05 | 1.07 | 0.04 **faster** |
| integral | integral_hdg | 0.37 | 0.35 | 1.06 |
| integral | integral_hd | 1.29 | 1.40 | 0.92 **faster** |
| erode | erode_hdg | 0.07 | 0.46 | 0.15 **faster** |
| erode | erode_hd5 | 0.33 | 0.77 | 0.43 **faster** |
| cvtColor | cvt_gray_hd | 0.09 | 0.40 | 0.22 **faster** |
| cvtColor | cvt_swap_hd | 0.10 | 0.05 | 1.84 |
| cvtColor | cvt_hsv_hd | 1.97 | 0.88 | 2.25 |
| cvtColor | cvt_ycrcb_hd | 0.56 | 0.62 | 0.90 **faster** |
| cvtColor | cvt_lab_hd | 2.23 | 0.68 | 3.28 |
| cvtColor | cvt_luv_hd | 1.97 | 0.94 | 2.09 |
| resize | resize_down_lin_hd | 0.04 | 0.25 | 0.18 **faster** |
| resize | resize_nn_hd | 0.17 | 0.25 | 0.70 **faster** |
| resize | resize_cub_hdg | 0.17 | 0.37 | 0.45 **faster** |
| resize | resize_lan_hdg | 1.76 | 3.77 | 0.47 **faster** |
| resize | resize_area_hd | 0.54 | 2.78 | 0.20 **faster** |
| resize | resize_area_frac | 0.74 | 2.90 | 0.25 **faster** |
| warpAffine | warp_rot_hd | 0.70 | 2.41 | 0.29 **faster** |
| warpAffine | warp_rot_hdg | 0.46 | 1.18 | 0.39 **faster** |
| remap | remap_lin_hd | 0.61 | 1.07 | 0.57 **faster** |
| remap | remap_lin_hdg | 0.40 | 0.92 | 0.44 **faster** |
| blobFromImage | blob_hd | 0.07 | 0.29 | 0.22 **faster** |
| Canny | canny_hdg | 4.88 | 1.43 | 3.40 |
| goodFeaturesToTrack | gftt_hdg | 2.84 | 22.53 | 0.13 **faster** |
| goodFeaturesToTrack | gftt_harris_hdg | 1.82 | 20.52 | 0.09 **faster** |
| line | line_diag_hd | 0.11 | 0.11 | 0.98 **faster** |
| line | line_thick_hd | 0.20 | 0.16 | 1.27 |
| HOGScores | hog_scores_hdg | 3.76 | 276.53 | 0.01 **faster** |
| detectMultiScale | hog_raw_hdg | 25.90 | 68.85 | 0.38 **faster** |
| detectMultiScale | hog_group_hdg | 27.60 | 68.75 | 0.40 **faster** |
| resize | resize_13_lin_hd | 0.25 | 0.39 | 0.64 **faster** |
| resize | resize_07_lin_hd | 0.35 | 1.29 | 0.27 **faster** |

## Other sizes (270x480 and smaller, point sets, stereo pairs)

| op | row | ours ms | cv2 ms | ours/cv2 |
|---|---|---:|---:|---:|
| Rodrigues | rod_vec | 0.00 | 0.00 | n/a |
| Rodrigues | rod_zero | 0.00 | 0.00 | n/a |
| Rodrigues | rod_mat | 0.01 | 0.00 | n/a |
| Rodrigues | rod_mat_pi | 0.00 | 0.00 | n/a |
| Rodrigues | rod_mat_id | 0.00 | 0.00 | n/a |
| projectPoints | proj_d4 | 0.00 | 0.01 | 0.13 **faster** |
| projectPoints | proj_d5 | 0.00 | 0.01 | 0.13 **faster** |
| projectPoints | proj_d8 | 0.00 | 0.01 | 0.11 **faster** |
| projectPoints | proj_d12 | 0.00 | 0.01 | 0.15 **faster** |
| projectPoints | proj_nodist | 0.00 | 0.01 | 0.13 **faster** |
| fisheye_projectPoints | fproj | 0.00 | 0.01 | 0.31 **faster** |
| undistortPoints | undist_d4 | 0.00 | 0.00 | n/a |
| undistortPoints | undist_d8 | 0.00 | 0.00 | n/a |
| undistortPoints | undist_rp | 0.00 | 0.01 | 0.49 **faster** |
| undistortPoints | undist_zero | 0.00 | 0.00 | n/a |
| fisheye_undistortPoints | fundist | 0.00 | 0.00 | n/a |
| fisheye_undistortPoints | fundist_rp | 0.00 | 0.00 | n/a |
| initUndistortRectifyMap | rectmap_d5 | 1.24 | 0.76 | 1.64 |
| initUndistortRectifyMap | rectmap_id | 0.03 | 0.01 | 4.74 |
| fisheye_initUndistortRectifyMap | frectmap | 0.49 | 1.20 | 0.41 **faster** |
| estimateAffine2D | aff_ransac | 0.01 | 0.03 | 0.52 **faster** |
| estimateAffine2D | aff_tight | 0.02 | 0.03 | 0.63 **faster** |
| solvePnP | pnp_d4 | 0.21 | 0.06 | 3.55 |
| solvePnP | pnp_planar | 0.09 | 0.07 | 1.18 |
| solvePnP | pnp_nodist | 0.36 | 0.08 | 4.20 |
| solvePnPRansac | pnp_ransac | 4.17 | 0.91 | 4.61 |
| findEssentialMat | ess_ransac | 14.91 | 2.01 | 7.42 |
| stereoRectify | rect_zero | 0.01 | 0.02 | 0.40 **faster** |
| stereoRectify | rect_dist | 0.01 | 0.02 | 0.41 **faster** |
| stereoRectify | rect_nozd | 0.01 | 0.02 | 0.39 **faster** |
| findEssentialMat | ess_noisy | 15.81 | 2.04 | 7.75 |
| recoverPose | pose_masked | 0.70 | 0.21 | 3.33 |
| recoverPose | pose_all | 0.95 | 0.21 | 4.49 |
| StereoSGBM | sgbm_dots | 10.66 | 2.42 | 4.40 |
| StereoSGBM | sgbm_block3 | 10.85 | 2.33 | 4.65 |
| StereoSGBM | sgbm_mind | 8.88 | 1.60 | 5.53 |
| findChessboardCorners | chess_a | 0.62 | 0.84 | 0.75 **faster** |
| findChessboardCorners | chess_b_rot | 0.60 | 1.01 | 0.60 **faster** |
| findChessboardCorners | chess_c | 0.49 | 3.59 | 0.14 **faster** |
| findChessboardCorners | chess_none | 6.01 | 10.31 | 0.58 **faster** |
| aruco_detect | aruco_four | 6.55 | 1.73 | 3.79 |
| aruco_detect | aruco_persp | 1.79 | 0.40 | 4.52 |
| aruco_detect | aruco_none | 1.49 | 0.64 | 2.34 |
| fisheye_projectPoints | fproj_zero_rot | 0.00 | 0.01 | 0.28 **faster** |
| fisheye_initUndistortRectifyMap | frectmap_small | 0.02 | 0.02 | 1.00 |
| solvePnPRansac | pnp_ransac_pl | 0.50 | 0.29 | 1.72 |
| solvePnP | pnp_epnp_four | 0.29 | 0.07 | 4.10 |
| solvePnP | pnp_epnp_noise | 0.33 | 0.08 | 3.94 |
| findEssentialMat | ess_five_minimal | 0.63 | 0.14 | 4.35 |
| findEssentialMat | ess_five_clean | 0.58 | 0.15 | 3.84 |
| findEssentialMat | ess_five_roots | 0.40 | 0.16 | 2.56 |
| stereoRectify | rect_alpha0 | 0.02 | 0.02 | 0.91 **faster** |
| stereoRectify | rect_alpha1 | 0.02 | 0.02 | 0.79 **faster** |
| stereoRectify | rect_vertical | 0.01 | 0.02 | 0.40 **faster** |
| stereoRectify | rect_vertical_a | 0.02 | 0.02 | 0.82 **faster** |
| flip | flip_y_odd | 0.01 | 0.00 | n/a |
| flip | flip_xy_one | 0.01 | 0.00 | n/a |
| flip | flip_y_f32 | 0.01 | 0.00 | n/a |
| rotate | rotate_180_odd | 0.01 | 0.00 | n/a |
| rotate | rotate_ccw_i16 | 0.01 | 0.00 | n/a |
| transpose | transpose_i32 | 0.01 | 0.00 | n/a |
| absdiff | absdiff_g1 | 0.01 | 0.00 | n/a |
| absdiff | absdiff_i16 | 0.01 | 0.00 | n/a |
| absdiff | absdiff_f32 | 0.01 | 0.00 | n/a |
| bitwise_or | bitwise_or_odd | 0.01 | 0.00 | n/a |
| bitwise_xor | bitwise_xor_f32 | 0.01 | 0.00 | n/a |
| bitwise_not | bitwise_not_one | 0.01 | 0.00 | n/a |
| convert | convert_f32_u8_half | 0.01 | 0.01 | 1.45 |
| convert | convert_f32_i16_scale | 0.01 | 0.01 | 0.91 **faster** |
| convert | convert_f64_i32 | 0.01 | 0.01 | 1.58 |
| convert | convert_u8_u8_one | 0.01 | 0.01 | 1.44 |
| bitwise_and | bitwise_and_odd | 0.01 | 0.00 | n/a |
| bitwise_xor | bitwise_xor_i16 | 0.01 | 0.00 | n/a |
| bfmatch | bf_ab | 0.73 | 0.44 | 1.68 |
| bfmatch | bf_one | 0.02 | 0.01 | 3.27 |
| bfmatch | bf_self | 0.53 | 0.13 | 4.22 |
| knnmatch | knn_ab | 0.81 | 0.47 | 1.71 |
| knnmatch | knn_ratio_tight | 0.44 | 0.46 | 0.96 **faster** |
| ORB | orb_sm | 2.25 | 1.97 | 1.14 |
| ORB | orb_blank | 0.20 | 0.03 | 7.72 |
| granulometry | gran_smg | 0.72 | 0.60 | 1.20 |
| granulometry | gran_bin | 6.26 | 3.23 | 1.94 |
| glcm | glcm_smg | 0.54 | 9.20 | 0.06 **faster** |
| lbpHist | lbp_smg | 0.25 | 7.72 | 0.03 **faster** |
| resizeMmpx | rmm_up_smg | 0.06 | 0.11 | 0.54 **faster** |
| granulometryMm | gmm_smg | 2.27 | 1.31 | 1.73 |
| tophat | tophat_smg | 1.28 | 1.66 | 0.77 **faster** |
| smoothFraction | smooth_smg | 0.17 | 1.16 | 0.15 **faster** |
| sharpMap | sharp_smg | 0.36 | 1.01 | 0.35 **faster** |
| autocorr | acorr_smg | 0.61 | 8.20 | 0.07 **faster** |
| waveletEnergy | wav_smg | 0.50 | 0.64 | 0.77 **faster** |
| trayRim | rim_binhd | 4.97 | 1.35 | 3.70 |
| granulometryRec | grec_smg | 4.84 | 16.55 | 0.29 **faster** |
| granulometryRec | grec_bin | 32.76 | 112.77 | 0.29 **faster** |
| trayRim | rim_syn | 0.57 | 0.18 | 3.24 |
| GaussianBlur | gauss5_odd | 0.01 | 0.00 | n/a |
| GaussianBlur | gauss5_smg | 0.01 | 0.08 | 0.15 **faster** |
| GaussianBlur | gauss5_sm | 0.02 | 0.13 | 0.14 **faster** |
| GaussianBlur | gauss7_odd | 0.01 | 0.01 | 0.88 **faster** |
| GaussianBlur | gauss_f32 | 0.01 | 0.00 | n/a |
| GaussianBlur | gauss3_one | 0.01 | 0.00 | n/a |
| pyrDown | pyrdown_smg | 0.01 | 0.04 | 0.25 **faster** |
| pyrDown | pyrdown_sm | 0.01 | 0.09 | 0.15 **faster** |
| pyrDown | pyrdown_odd | 0.01 | 0.00 | n/a |
| pyrDown | pyrdown_one | 0.01 | 0.00 | n/a |
| pyrDown | pyrdown_f32 | 0.01 | 0.00 | n/a |
| Sobel | sobel_scharr_g1 | 0.01 | 0.00 | n/a |
| Sobel | sobel_f32_dxx | 0.01 | 0.00 | n/a |
| threshold | thresh_inv_sm | 0.01 | 0.01 | 1.59 |
| threshold | thresh_trunc_g1 | 0.01 | 0.00 | n/a |
| threshold | thresh_tozero_g1 | 0.01 | 0.00 | n/a |
| threshold | thresh_otsu_one | 0.01 | 0.00 | n/a |
| threshold | thresh_tri_bin | 0.01 | 0.08 | 0.14 **faster** |
| threshold | thresh_tri_blank | 0.01 | 0.00 | n/a |
| threshold | thresh_tri_g2 | 0.01 | 0.00 | n/a |
| threshold | thresh_f32 | 0.01 | 0.00 | n/a |
| integral | integral_odd | 0.01 | 0.00 | n/a |
| integral | integral_f32 | 0.01 | 0.00 | n/a |
| integral | integral_one | 0.01 | 0.00 | n/a |
| dilate | dilate_cross_sm | 0.11 | 0.06 | 1.68 |
| dilate | dilate_ell_smg | 0.08 | 0.08 | 0.90 **faster** |
| erode | erode_ell_odd | 0.02 | 0.00 | n/a |
| dilate | dilate_one | 0.02 | 0.00 | n/a |
| erode | erode_f32 | 0.02 | 0.00 | n/a |
| cvtColor | cvt_rgb2gray_odd | 0.01 | 0.00 | n/a |
| cvtColor | cvt_gray2bgr_g1 | 0.01 | 0.00 | n/a |
| cvtColor | cvt_hsv_odd | 0.01 | 0.00 | n/a |
| cvtColor | cvt_hsv_one | 0.01 | 0.00 | n/a |
| cvtColor | cvt_hsv2bgr_odd | 0.01 | 0.00 | n/a |
| cvtColor | cvt_ycrcb2bgr_sm | 0.07 | 0.08 | 0.98 **faster** |
| cvtColor | cvt_gray_f32 | 0.01 | 0.00 | n/a |
| cvtColor | cvt_lab_one | 0.18 | 0.00 | n/a |
| cvtColor | cvt_lab_f32 | 0.18 | 0.00 | n/a |
| cvtColor | cvt_lab2bgr_sm | 0.32 | 0.25 | 1.32 |
| cvtColor | cvt_lab2bgr_one | 0.18 | 0.00 | n/a |
| cvtColor | cvt_luv_odd | 0.18 | 0.00 | n/a |
| cvtColor | cvt_luv_f32 | 0.19 | 0.00 | n/a |
| cvtColor | cvt_luv2bgr_sm | 0.31 | 0.32 | 0.99 **faster** |
| cvtColor | cvt_luv2bgr_f32 | 0.34 | 0.23 | 1.46 |
| cvtColor | cvt_lab2bgr_f32 | 0.31 | 0.42 | 0.74 **faster** |
| resize | resize_up_lin_sm | 0.12 | 0.42 | 0.30 **faster** |
| resize | resize_nn_odd | 0.01 | 0.00 | n/a |
| resize | resize_cub_sm | 0.38 | 0.46 | 0.83 **faster** |
| resize | resize_lan_sm | 0.16 | 1.54 | 0.11 **faster** |
| resize | resize_lin_one | 0.01 | 0.00 | n/a |
| resize | resize_lin_f32 | 0.01 | 0.00 | n/a |
| resize | resize_half_g | 0.01 | 0.01 | 1.06 |
| resize | resize_half_c | 0.01 | 0.03 | 0.33 **faster** |
| resize | resize_area_up2 | 0.35 | 0.66 | 0.53 **faster** |
| resize | resize_area_shrinkx | 0.10 | 0.40 | 0.24 **faster** |
| resize | resize_area_up | 0.41 | 0.51 | 0.80 **faster** |
| resize | resize_area_odd | 0.01 | 0.00 | n/a |
| resize | resize_area_one | 0.01 | 0.00 | n/a |
| resize | resize_area_f32 | 0.01 | 0.00 | n/a |
| warpAffine | warp_rot_sm | 0.04 | 0.15 | 0.25 **faster** |
| warpAffine | warp_nn_sm | 0.27 | 0.16 | 1.68 |
| warpAffine | warp_cub_smg | 0.51 | 0.56 | 0.91 **faster** |
| warpAffine | warp_rep_odd | 0.01 | 0.01 | 1.31 |
| warpAffine | warp_inv_g1 | 0.01 | 0.01 | 2.66 |
| warpAffine | warp_f32 | 0.01 | 0.01 | 1.98 |
| remap | remap_lin_sm | 0.21 | 0.97 | 0.22 **faster** |
| remap | remap_nn_sm | 0.28 | 0.08 | 3.39 |
| remap | remap_cub_smg | 0.43 | 0.38 | 1.12 |
| remap | remap_odd_const | 0.01 | 0.00 | n/a |
| remap | remap_odd_refl | 0.01 | 0.00 | n/a |
| blobFromImage | blob_sm | 0.05 | 0.26 | 0.20 **faster** |
| connectedComponentsWithStats | ccl8_bin | 1.42 | 0.44 | 3.27 |
| connectedComponentsWithStats | ccl4_binhd | 17.18 | 2.52 | 6.81 |
| connectedComponentsWithStats | ccl8_shapes | 0.04 | 0.04 | 1.10 |
| connectedComponentsWithStats | ccl_blank | 0.00 | 0.00 | n/a |
| Canny | canny_smg_l2 | 0.39 | 0.27 | 1.47 |
| Canny | canny_sm5 | 0.48 | 0.21 | 2.22 |
| Canny | canny_blank | 0.03 | 0.01 | 2.88 |
| Canny | canny_g1 | 0.03 | 0.01 | 3.96 |
| findContours | contours_ext_shapes | 0.02 | 0.02 | 1.10 |
| findContours | contours_list_shapes | 0.02 | 0.02 | 0.97 **faster** |
| findContours | contours_simple_shapes | 0.02 | 0.02 | 0.95 **faster** |
| findContours | contours_ext_bin | 0.50 | 0.20 | 2.55 |
| findContours | contours_list_bin | 0.56 | 0.57 | 0.98 **faster** |
| findContours | contours_blank | 0.00 | 0.00 | n/a |
| findContours | contours_full | 0.00 | 0.01 | 0.27 **faster** |
| findContours | contours_ccomp_shapes | 0.02 | 0.02 | 1.02 |
| findContours | contours_tree_shapes | 0.02 | 0.02 | 0.95 **faster** |
| findContours | contours_tree_simple | 0.02 | 0.02 | 0.87 **faster** |
| findContours | contours_ccomp_bin | 0.54 | 0.64 | 0.84 **faster** |
| findContours | contours_tree_bin | 0.55 | 0.66 | 0.84 **faster** |
| findContours | contours_tree_binhd | 8.25 | 10.30 | 0.80 **faster** |
| findContours | contours_tree_blank | 0.00 | 0.00 | n/a |
| findContours | contours_tree_full | 0.00 | 0.01 | 0.19 **faster** |
| goodFeaturesToTrack | gftt_smg | 0.23 | 1.86 | 0.13 **faster** |
| goodFeaturesToTrack | gftt_blank | 0.06 | 0.01 | 6.21 |
| goodFeaturesToTrack | gftt_harris_smg | 0.19 | 1.65 | 0.12 **faster** |
| goodFeaturesToTrack | gftt_harris_blank | 0.06 | 0.01 | 5.42 |
| line | line_steep_g1 | 0.00 | 0.00 | n/a |
| line | line_clip_sm | 0.01 | 0.01 | 0.74 **faster** |
| line | line_out_sm | 0.01 | 0.01 | 0.57 **faster** |
| line | line_thick_g1 | 0.00 | 0.00 | n/a |
| line | line_thick_flat | 0.02 | 0.01 | 1.31 |
| line | line_thick_dot | 0.01 | 0.01 | 0.68 **faster** |
| line | line_thick_clip | 0.03 | 0.02 | 1.46 |
| rectangle | rect_thick_sm | 0.04 | 0.02 | 1.82 |
| line | line_hor_odd | 0.00 | 0.00 | n/a |
| rectangle | rect_edge_sm | 0.01 | 0.01 | 0.79 **faster** |
| rectangle | rect_fill_odd | 0.00 | 0.00 | n/a |
| HOGScores | hog_scores_smg | 0.20 | 12.26 | 0.02 **faster** |
| detectMultiScale | hog_raw_smg | 1.82 | 3.79 | 0.48 **faster** |
| detectMultiScale | hog_group_smg | 1.90 | 2.97 | 0.64 **faster** |
| detectMultiScale | hog_group_smg2 | 1.84 | 3.25 | 0.56 **faster** |
| detectMultiScale | hog_none | 2.00 | 3.50 | 0.57 **faster** |
| groupRectangles | group_rects_hdg | 0.75 | 1.10 | 0.68 **faster** |
| grabCut | grabcut_scene | 35.20 | 10.75 | 3.27 |
| grabCut | grabcut_shot | 53.00 | 8.97 | 5.91 |
| grabCut | grabcut_tiny | 0.10 | 0.06 | 1.65 |
| cornerSubPix | subpix_sm | 1.14 | 0.52 | 2.21 |
| cornerSubPix | subpix_win3 | 0.56 | 0.30 | 1.85 |
| cornerSubPix | subpix_edge | 3.25 | 1.18 | 2.76 |
| calcOpticalFlowPyrLK | lk_sm | 9.48 | 1.45 | 6.53 |
| calcOpticalFlowPyrLK | lk_sm_win9 | 5.79 | 0.41 | 14.24 |
| calcOpticalFlowFarneback | fb_shift | 19.96 | 16.87 | 1.18 |
| calcOpticalFlowFarneback | fb_frames | 19.95 | 16.66 | 1.20 |
| calcOpticalFlowFarneback | fb_poly7 | 17.24 | 16.73 | 1.03 |
| calcOpticalFlowFarneback | fb_tiny | 1.16 | 0.01 | 95.95 |
