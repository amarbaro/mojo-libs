# L2D speed rows: mojo-cv vs cv2 5.0

Method: `tests/run.sh --bench-all --md docs/bench.md`. Each row runs the same op in one resident process with `reps=5`
and keeps the best wall time of the compute only (file load and save excluded), ours via `.bin/mojo-cv`, cv2 via
`tools/oracle_cv2.py` (numpy in, cv2 call, best of 5). Both sides use all threads of the 7800X3D; CPU only, no GPU.
Inputs are the same `.mcv` fixtures (`hd*` = 1920x1080 crops of a real screenshot, the rest smaller). Target from
`docs/provenance/2d.md`: ours <= cv2. **Misses are listed as measured; nothing is hidden.** The HOG rows time cv2 4.8.1
(cv2 5.0 has no HOG).

1080p rows: 4 of 39 faster than cv2, 1 more within 1.5x, the rest slower (ratio column).

- **Parallel dispatch**: `max.algorithm.parallelize` with the default 16 workers costs about 215 us per region (best of
  50 trivial regions); with 8 workers (the physical cores) it costs about 8 us, so `core.par` uses 8 and takes 16 only for
  regions that run for milliseconds. A cached CPU DeviceContext changed nothing. Allocating and zero-filling a 2 MB `Mat`
  is 18 us. Probes: measured in a scratch build, numbers quoted in the lane report.
- The stencil, resize, pyrDown, Canny and LK loops are scalar per-pixel code with `Mat.at` bounds checks and are not
  tuned; cv2's are hand-vectorised. HOG detection re-sums every 16x16 block (each pixel 4 times).
- Faster than cv2 on 1080p: `convert` u8 to f32 (cv2's path is slow), Otsu, `line`, absdiff and bitwise, HOG window scoring
  at one scale, `groupRectangles`. Point-set ops (projectPoints, estimateAffine2D, stereoRectify) take microseconds on both
  sides; 0.00 ms entries are below the timer's resolution, not a result.

## 1920x1080 rows

| op | row | ours ms | cv2 ms | ours/cv2 |
|---|---|---:|---:|---:|
| flip | flip_x_hd | 2.10 | 0.15 | 14.44 |
| rotate | rotate_cw_hd | 2.58 | 1.03 | 2.51 |
| transpose | transpose_hd | 1.70 | 0.21 | 8.06 |
| absdiff | absdiff_hd | 0.97 | 0.26 | 3.77 |
| bitwise_and | bitwise_and_hd | 0.93 | 0.21 | 4.42 |
| bitwise_not | bitwise_not_hd | 0.80 | 0.20 | 4.08 |
| convert | convert_u8_f32_hd | 1.89 | 18.69 | 0.10 **faster** |
| bitwise_or | bitwise_or_hd | 0.36 | 0.23 | 1.55 |
| bitwise_xor | bitwise_xor_hd | 0.60 | 0.21 | 2.83 |
| ORB | orb_hd | 146.45 | 18.67 | 7.84 |
| GaussianBlur | gauss5_hd | 2.66 | 0.52 | 5.13 |
| GaussianBlur | gauss_s2_hdg | 2.46 | 1.12 | 2.20 |
| pyrDown | pyrdown_hd | 5.14 | 0.65 | 7.97 |
| Sobel | sobel_dx_hdg | 1.68 | 0.42 | 4.00 |
| Sobel | sobel_dy5_hd | 3.11 | 1.98 | 1.57 |
| threshold | thresh_bin_hdg | 0.76 | 0.06 | 12.65 |
| threshold | thresh_tozinv_hd | 0.12 | 0.07 | 1.84 |
| threshold | thresh_otsu_hdg | 0.26 | 1.04 | 0.25 **faster** |
| integral | integral_hdg | 4.00 | 0.35 | 11.37 |
| integral | integral_hd | 5.93 | 1.75 | 3.38 |
| erode | erode_hdg | 1.23 | 0.12 | 10.41 |
| erode | erode_hd5 | 6.10 | 0.38 | 16.09 |
| cvtColor | cvt_gray_hd | 0.71 | 0.11 | 6.42 |
| cvtColor | cvt_swap_hd | 1.09 | 0.08 | 13.27 |
| cvtColor | cvt_hsv_hd | 2.24 | 1.57 | 1.43 |
| cvtColor | cvt_ycrcb_hd | 2.99 | 0.32 | 9.41 |
| resize | resize_down_lin_hd | 2.92 | 0.27 | 10.71 |
| resize | resize_nn_hd | 0.61 | 0.14 | 4.48 |
| resize | resize_cub_hdg | 1.77 | 0.66 | 2.69 |
| resize | resize_lan_hdg | 9.23 | 5.01 | 1.84 |
| warpAffine | warp_rot_hd | 16.86 | 5.52 | 3.05 |
| remap | remap_lin_hd | 6.31 | 2.34 | 2.70 |
| blobFromImage | blob_hd | 1.80 | 0.20 | 9.08 |
| Canny | canny_hdg | 14.13 | 1.15 | 12.28 |
| goodFeaturesToTrack | gftt_hdg | 82.94 | 26.71 | 3.11 |
| line | line_diag_hd | 0.12 | 0.14 | 0.91 **faster** |
| HOGScores | hog_scores_hdg | 88.16 | 411.41 | 0.21 **faster** |
| detectMultiScale | hog_raw_hdg | 1137.89 | 113.96 | 9.99 |
| detectMultiScale | hog_group_hdg | 1209.50 | 123.75 | 9.77 |

## Other sizes (270x480 and smaller, point sets, stereo pairs)

| op | row | ours ms | cv2 ms | ours/cv2 |
|---|---|---:|---:|---:|
| Rodrigues | rod_vec | 0.00 | 0.00 | n/a |
| Rodrigues | rod_zero | 0.00 | 0.00 | n/a |
| Rodrigues | rod_mat | 0.01 | 0.00 | n/a |
| Rodrigues | rod_mat_pi | 0.00 | 0.00 | n/a |
| Rodrigues | rod_mat_id | 0.00 | 0.00 | n/a |
| projectPoints | proj_d4 | 0.00 | 0.01 | 0.18 **faster** |
| projectPoints | proj_d5 | 0.00 | 0.01 | 0.11 **faster** |
| projectPoints | proj_d8 | 0.00 | 0.01 | 0.17 **faster** |
| projectPoints | proj_d12 | 0.00 | 0.01 | 0.23 **faster** |
| projectPoints | proj_nodist | 0.00 | 0.01 | 0.15 **faster** |
| fisheye_projectPoints | fproj | 0.00 | 0.01 | 0.37 **faster** |
| undistortPoints | undist_d4 | 0.00 | 0.00 | n/a |
| undistortPoints | undist_d8 | 0.00 | 0.00 | n/a |
| undistortPoints | undist_rp | 0.00 | 0.01 | 0.63 **faster** |
| undistortPoints | undist_zero | 0.00 | 0.00 | n/a |
| fisheye_undistortPoints | fundist | 0.00 | 0.00 | n/a |
| fisheye_undistortPoints | fundist_rp | 0.01 | 0.00 | n/a |
| initUndistortRectifyMap | rectmap_d5 | 2.06 | 0.43 | 4.81 |
| initUndistortRectifyMap | rectmap_id | 0.69 | 0.01 | 74.40 |
| fisheye_initUndistortRectifyMap | frectmap | 2.54 | 1.28 | 1.98 |
| estimateAffine2D | aff_ransac | 0.02 | 0.03 | 0.85 **faster** |
| estimateAffine2D | aff_tight | 0.02 | 0.03 | 0.54 **faster** |
| solvePnP | pnp_d4 | 0.36 | 0.06 | 5.58 |
| solvePnP | pnp_planar | 0.08 | 0.08 | 0.97 **faster** |
| solvePnP | pnp_nodist | 0.44 | 0.09 | 4.85 |
| solvePnPRansac | pnp_ransac | 6.05 | 1.00 | 6.03 |
| findEssentialMat | ess_ransac | 2.81 | 2.28 | 1.23 |
| stereoRectify | rect_zero | 0.01 | 0.02 | 0.57 **faster** |
| stereoRectify | rect_dist | 0.01 | 0.02 | 0.58 **faster** |
| stereoRectify | rect_nozd | 0.01 | 0.02 | 0.63 **faster** |
| findEssentialMat | ess_noisy | 7.73 | 2.67 | 2.89 |
| recoverPose | pose_masked | 1.15 | 0.23 | 5.02 |
| recoverPose | pose_all | 1.26 | 0.22 | 5.83 |
| StereoSGBM | sgbm_dots | 19.11 | 2.23 | 8.58 |
| StereoSGBM | sgbm_block3 | 20.01 | 2.36 | 8.48 |
| StereoSGBM | sgbm_mind | 9.68 | 1.60 | 6.04 |
| findChessboardCorners | chess_a | 24.83 | 0.79 | 31.34 |
| findChessboardCorners | chess_b_rot | 13.01 | 0.89 | 14.66 |
| findChessboardCorners | chess_c | 18.44 | 3.94 | 4.69 |
| findChessboardCorners | chess_none | 23.68 | 10.29 | 2.30 |
| aruco_detect | aruco_four | 20.65 | 0.97 | 21.20 |
| aruco_detect | aruco_persp | 5.62 | 0.60 | 9.36 |
| aruco_detect | aruco_none | 6.14 | 0.74 | 8.27 |
| fisheye_projectPoints | fproj_zero_rot | 0.00 | 0.01 | 0.29 **faster** |
| fisheye_initUndistortRectifyMap | frectmap_small | 0.24 | 0.02 | 15.33 |
| solvePnPRansac | pnp_ransac_pl | 0.73 | 0.32 | 2.27 |
| flip | flip_y_odd | 1.17 | 0.00 | n/a |
| flip | flip_xy_one | 1.22 | 0.00 | n/a |
| flip | flip_y_f32 | 0.23 | 0.00 | n/a |
| rotate | rotate_180_odd | 0.31 | 0.00 | n/a |
| rotate | rotate_ccw_i16 | 1.00 | 0.00 | n/a |
| transpose | transpose_i32 | 0.52 | 0.00 | n/a |
| absdiff | absdiff_g1 | 0.22 | 0.00 | n/a |
| absdiff | absdiff_i16 | 1.06 | 0.00 | n/a |
| absdiff | absdiff_f32 | 0.22 | 0.00 | n/a |
| bitwise_or | bitwise_or_odd | 0.84 | 0.00 | n/a |
| bitwise_xor | bitwise_xor_f32 | 0.42 | 0.00 | n/a |
| bitwise_not | bitwise_not_one | 0.23 | 0.00 | n/a |
| convert | convert_f32_u8_half | 0.22 | 0.01 | 28.01 |
| convert | convert_f32_i16_scale | 1.06 | 0.01 | 102.12 |
| convert | convert_f64_i32 | 0.24 | 0.01 | 28.85 |
| convert | convert_u8_u8_one | 0.87 | 0.01 | 101.62 |
| bitwise_and | bitwise_and_odd | 0.57 | 0.00 | n/a |
| bitwise_xor | bitwise_xor_i16 | 0.39 | 0.00 | n/a |
| bfmatch | bf_ab | 2.01 | 0.23 | 8.93 |
| bfmatch | bf_one | 0.22 | 0.01 | 29.77 |
| bfmatch | bf_self | 1.51 | 0.28 | 5.38 |
| knnmatch | knn_ab | 2.60 | 0.50 | 5.18 |
| knnmatch | knn_ratio_tight | 1.85 | 0.30 | 6.06 |
| ORB | orb_sm | 41.37 | 2.00 | 20.64 |
| ORB | orb_blank | 28.70 | 0.03 | 936.03 |
| GaussianBlur | gauss7_odd | 1.11 | 0.01 | 122.47 |
| GaussianBlur | gauss_f32 | 0.96 | 0.00 | n/a |
| GaussianBlur | gauss3_one | 0.11 | 0.00 | n/a |
| pyrDown | pyrdown_odd | 0.66 | 0.00 | n/a |
| pyrDown | pyrdown_one | 0.67 | 0.00 | n/a |
| pyrDown | pyrdown_f32 | 0.03 | 0.00 | n/a |
| Sobel | sobel_scharr_g1 | 0.03 | 0.00 | n/a |
| Sobel | sobel_f32_dxx | 0.65 | 0.00 | n/a |
| threshold | thresh_inv_sm | 0.67 | 0.01 | 79.07 |
| threshold | thresh_trunc_g1 | 0.01 | 0.00 | n/a |
| threshold | thresh_tozero_g1 | 0.64 | 0.00 | n/a |
| threshold | thresh_otsu_one | 0.44 | 0.00 | n/a |
| threshold | thresh_f32 | 0.64 | 0.00 | n/a |
| integral | integral_odd | 0.49 | 0.00 | n/a |
| integral | integral_f32 | 1.22 | 0.00 | n/a |
| integral | integral_one | 1.31 | 0.00 | n/a |
| dilate | dilate_cross_sm | 0.12 | 0.06 | 2.02 |
| dilate | dilate_ell_smg | 2.44 | 0.08 | 28.77 |
| erode | erode_ell_odd | 0.45 | 0.00 | n/a |
| dilate | dilate_one | 2.23 | 0.00 | n/a |
| erode | erode_f32 | 1.69 | 0.00 | n/a |
| cvtColor | cvt_rgb2gray_odd | 0.24 | 0.00 | n/a |
| cvtColor | cvt_gray2bgr_g1 | 0.64 | 0.00 | n/a |
| cvtColor | cvt_hsv_odd | 1.06 | 0.00 | n/a |
| cvtColor | cvt_hsv_one | 0.24 | 0.00 | n/a |
| cvtColor | cvt_hsv2bgr_odd | 0.85 | 0.00 | n/a |
| cvtColor | cvt_ycrcb2bgr_sm | 0.14 | 0.07 | 1.86 |
| cvtColor | cvt_gray_f32 | 0.01 | 0.00 | n/a |
| resize | resize_up_lin_sm | 0.73 | 0.32 | 2.29 |
| resize | resize_nn_odd | 2.29 | 0.00 | n/a |
| resize | resize_cub_sm | 3.02 | 0.14 | 21.14 |
| resize | resize_lan_sm | 1.14 | 1.65 | 0.69 **faster** |
| resize | resize_lin_one | 0.73 | 0.00 | n/a |
| resize | resize_lin_f32 | 0.45 | 0.00 | n/a |
| warpAffine | warp_nn_sm | 1.51 | 0.16 | 9.61 |
| warpAffine | warp_cub_smg | 0.89 | 0.18 | 4.94 |
| warpAffine | warp_rep_odd | 1.05 | 0.01 | 139.63 |
| warpAffine | warp_inv_g1 | 0.01 | 0.01 | 1.76 |
| warpAffine | warp_f32 | 0.48 | 0.01 | 64.45 |
| remap | remap_nn_sm | 0.90 | 0.12 | 7.62 |
| remap | remap_cub_smg | 2.38 | 0.33 | 7.11 |
| remap | remap_odd_const | 0.85 | 0.00 | n/a |
| remap | remap_odd_refl | 1.37 | 0.00 | n/a |
| blobFromImage | blob_sm | 1.53 | 0.21 | 7.39 |
| connectedComponentsWithStats | ccl8_bin | 1.94 | 0.63 | 3.09 |
| connectedComponentsWithStats | ccl4_binhd | 29.66 | 3.96 | 7.48 |
| connectedComponentsWithStats | ccl8_shapes | 0.05 | 0.03 | 1.52 |
| connectedComponentsWithStats | ccl_blank | 0.00 | 0.00 | n/a |
| Canny | canny_smg_l2 | 0.59 | 0.36 | 1.62 |
| Canny | canny_sm5 | 3.25 | 0.34 | 9.43 |
| Canny | canny_blank | 0.09 | 0.01 | 8.50 |
| Canny | canny_g1 | 1.79 | 0.01 | 209.04 |
| findContours | contours_ext_shapes | 0.03 | 0.02 | 1.80 |
| findContours | contours_list_shapes | 0.02 | 0.02 | 0.88 **faster** |
| findContours | contours_simple_shapes | 0.02 | 0.02 | 0.83 **faster** |
| findContours | contours_ext_bin | 0.75 | 0.06 | 11.58 |
| findContours | contours_list_bin | 0.76 | 0.28 | 2.73 |
| findContours | contours_blank | 0.00 | 0.00 | n/a |
| findContours | contours_full | 0.00 | 0.01 | 0.30 **faster** |
| goodFeaturesToTrack | gftt_smg | 2.34 | 1.93 | 1.21 |
| goodFeaturesToTrack | gftt_blank | 0.13 | 0.01 | 12.64 |
| line | line_steep_g1 | 0.00 | 0.00 | n/a |
| line | line_clip_sm | 0.01 | 0.01 | 0.89 **faster** |
| line | line_out_sm | 0.01 | 0.01 | 0.89 **faster** |
| line | line_hor_odd | 0.00 | 0.00 | n/a |
| rectangle | rect_edge_sm | 0.02 | 0.01 | 1.22 |
| rectangle | rect_fill_odd | 0.00 | 0.00 | n/a |
| HOGScores | hog_scores_smg | 5.93 | 13.28 | 0.45 **faster** |
| detectMultiScale | hog_raw_smg | 113.01 | 6.35 | 17.79 |
| detectMultiScale | hog_group_smg | 124.18 | 5.76 | 21.56 |
| detectMultiScale | hog_group_smg2 | 107.53 | 4.92 | 21.84 |
| detectMultiScale | hog_none | 132.73 | 5.83 | 22.77 |
| groupRectangles | group_rects_hdg | 1.01 | 2.41 | 0.42 **faster** |
| grabCut | grabcut_scene | 55.91 | 12.70 | 4.40 |
| grabCut | grabcut_shot | 89.74 | 16.09 | 5.58 |
| grabCut | grabcut_tiny | 0.15 | 0.06 | 2.29 |
| cornerSubPix | subpix_sm | 1.49 | 0.62 | 2.41 |
| cornerSubPix | subpix_win3 | 1.30 | 0.34 | 3.80 |
| cornerSubPix | subpix_edge | 3.60 | 1.14 | 3.17 |
| calcOpticalFlowPyrLK | lk_sm | 22.83 | 0.80 | 28.49 |
| calcOpticalFlowPyrLK | lk_sm_win9 | 19.59 | 0.18 | 109.82 |
| calcOpticalFlowFarneback | fb_shift | 126.16 | 22.97 | 5.49 |
| calcOpticalFlowFarneback | fb_frames | 110.08 | 25.58 | 4.30 |
| calcOpticalFlowFarneback | fb_poly7 | 60.16 | 22.45 | 2.68 |
| calcOpticalFlowFarneback | fb_tiny | 1.60 | 0.01 | 124.40 |
