# L2D speed rows: mojo-cv vs cv2 5.0

Method: `tests/run.sh --bench-all --md docs/bench.md`. Each row runs the same op in one resident process with `reps=5`
and keeps the best wall time of the compute only (file load and save excluded), ours via `.bin/mojo-cv`, cv2 via
`tools/oracle_cv2.py` (numpy in, cv2 call, best of 5). Both sides use all threads of the 7800X3D; CPU only, no GPU.
Inputs are the same `.mcv` fixtures (`hd*` = 1920x1080 crops of a real screenshot, the rest smaller). Target from
`docs/provenance/2d.md`: ours <= cv2. **Misses are listed as measured; nothing is hidden.** The HOG rows time cv2 4.8.1
(cv2 5.0 has no HOG).

1080p rows: 10 of 39 faster than cv2, 3 more within 1.5x, the rest slower (ratio column).

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
| flip | flip_x_hd | 0.75 | 0.17 | 4.32 |
| rotate | rotate_cw_hd | 1.30 | 1.12 | 1.16 |
| transpose | transpose_hd | 0.86 | 0.14 | 5.93 |
| absdiff | absdiff_hd | 0.13 | 0.28 | 0.47 **faster** |
| bitwise_and | bitwise_and_hd | 0.13 | 0.23 | 0.55 **faster** |
| bitwise_not | bitwise_not_hd | 0.11 | 0.17 | 0.64 **faster** |
| convert | convert_u8_f32_hd | 0.43 | 16.31 | 0.03 **faster** |
| bitwise_or | bitwise_or_hd | 0.12 | 0.21 | 0.58 **faster** |
| bitwise_xor | bitwise_xor_hd | 0.13 | 0.21 | 0.62 **faster** |
| ORB | orb_hd | 59.82 | 14.27 | 4.19 |
| GaussianBlur | gauss5_hd | 2.51 | 0.42 | 6.02 |
| GaussianBlur | gauss_s2_hdg | 1.15 | 0.67 | 1.72 |
| pyrDown | pyrdown_hd | 4.13 | 0.50 | 8.25 |
| Sobel | sobel_dx_hdg | 0.64 | 0.17 | 3.77 |
| Sobel | sobel_dy5_hd | 2.02 | 1.54 | 1.32 |
| threshold | thresh_bin_hdg | 0.05 | 0.02 | 2.14 |
| threshold | thresh_tozinv_hd | 0.12 | 0.05 | 2.64 |
| threshold | thresh_otsu_hdg | 0.05 | 1.09 | 0.05 **faster** |
| integral | integral_hdg | 1.33 | 0.34 | 3.88 |
| integral | integral_hd | 3.73 | 1.60 | 2.33 |
| erode | erode_hdg | 0.38 | 1.14 | 0.33 **faster** |
| erode | erode_hd5 | 2.31 | 0.20 | 11.84 |
| cvtColor | cvt_gray_hd | 0.42 | 0.08 | 5.28 |
| cvtColor | cvt_swap_hd | 0.92 | 0.08 | 11.15 |
| cvtColor | cvt_hsv_hd | 2.02 | 0.81 | 2.49 |
| cvtColor | cvt_ycrcb_hd | 1.73 | 0.21 | 8.22 |
| resize | resize_down_lin_hd | 2.10 | 0.42 | 4.99 |
| resize | resize_nn_hd | 0.58 | 0.09 | 6.43 |
| resize | resize_cub_hdg | 1.14 | 0.12 | 9.20 |
| resize | resize_lan_hdg | 5.00 | 3.75 | 1.33 |
| warpAffine | warp_rot_hd | 8.63 | 1.12 | 7.68 |
| remap | remap_lin_hd | 4.84 | 1.34 | 3.62 |
| blobFromImage | blob_hd | 0.87 | 0.30 | 2.88 |
| Canny | canny_hdg | 44.39 | 4.87 | 9.12 |
| goodFeaturesToTrack | gftt_hdg | 46.46 | 26.95 | 1.72 |
| line | line_diag_hd | 0.24 | 0.29 | 0.82 **faster** |
| HOGScores | hog_scores_hdg | 55.39 | 342.99 | 0.16 **faster** |
| detectMultiScale | hog_raw_hdg | 637.41 | 74.78 | 8.52 |
| detectMultiScale | hog_group_hdg | 633.23 | 79.56 | 7.96 |

## Other sizes (270x480 and smaller, point sets, stereo pairs)

| op | row | ours ms | cv2 ms | ours/cv2 |
|---|---|---:|---:|---:|
| Rodrigues | rod_vec | 0.00 | 0.00 | n/a |
| Rodrigues | rod_zero | 0.00 | 0.00 | n/a |
| Rodrigues | rod_mat | 0.01 | 0.00 | n/a |
| Rodrigues | rod_mat_pi | 0.00 | 0.00 | n/a |
| Rodrigues | rod_mat_id | 0.00 | 0.00 | n/a |
| projectPoints | proj_d4 | 0.00 | 0.01 | 0.12 **faster** |
| projectPoints | proj_d5 | 0.00 | 0.01 | 0.13 **faster** |
| projectPoints | proj_d8 | 0.00 | 0.01 | 0.10 **faster** |
| projectPoints | proj_d12 | 0.00 | 0.01 | 0.13 **faster** |
| projectPoints | proj_nodist | 0.00 | 0.01 | 0.12 **faster** |
| fisheye_projectPoints | fproj | 0.00 | 0.01 | 0.28 **faster** |
| undistortPoints | undist_d4 | 0.00 | 0.00 | n/a |
| undistortPoints | undist_d8 | 0.00 | 0.00 | n/a |
| undistortPoints | undist_rp | 0.00 | 0.01 | 0.44 **faster** |
| undistortPoints | undist_zero | 0.00 | 0.00 | n/a |
| fisheye_undistortPoints | fundist | 0.00 | 0.00 | n/a |
| fisheye_undistortPoints | fundist_rp | 0.00 | 0.00 | n/a |
| initUndistortRectifyMap | rectmap_d5 | 2.08 | 0.21 | 9.91 |
| initUndistortRectifyMap | rectmap_id | 0.04 | 0.01 | 5.81 |
| fisheye_initUndistortRectifyMap | frectmap | 0.58 | 1.26 | 0.46 **faster** |
| estimateAffine2D | aff_ransac | 0.01 | 0.03 | 0.43 **faster** |
| estimateAffine2D | aff_tight | 0.03 | 0.03 | 1.02 |
| solvePnP | pnp_d4 | 0.26 | 0.06 | 4.15 |
| solvePnP | pnp_planar | 0.08 | 0.08 | 0.94 **faster** |
| solvePnP | pnp_nodist | 0.31 | 0.09 | 3.35 |
| solvePnPRansac | pnp_ransac | 3.85 | 0.99 | 3.88 |
| findEssentialMat | ess_ransac | 2.30 | 2.19 | 1.05 |
| stereoRectify | rect_zero | 0.01 | 0.02 | 0.36 **faster** |
| stereoRectify | rect_dist | 0.01 | 0.02 | 0.36 **faster** |
| stereoRectify | rect_nozd | 0.01 | 0.02 | 0.34 **faster** |
| findEssentialMat | ess_noisy | 6.70 | 2.74 | 2.44 |
| recoverPose | pose_masked | 0.70 | 0.23 | 3.05 |
| recoverPose | pose_all | 1.00 | 0.23 | 4.32 |
| StereoSGBM | sgbm_dots | 9.87 | 2.06 | 4.80 |
| StereoSGBM | sgbm_block3 | 9.02 | 2.15 | 4.20 |
| StereoSGBM | sgbm_mind | 6.30 | 1.71 | 3.69 |
| findChessboardCorners | chess_a | 6.85 | 0.79 | 8.67 |
| findChessboardCorners | chess_b_rot | 7.66 | 1.01 | 7.59 |
| findChessboardCorners | chess_c | 6.51 | 3.94 | 1.65 |
| findChessboardCorners | chess_none | 7.44 | 10.67 | 0.70 **faster** |
| aruco_detect | aruco_four | 7.74 | 1.20 | 6.45 |
| aruco_detect | aruco_persp | 2.60 | 0.43 | 6.09 |
| aruco_detect | aruco_none | 3.47 | 0.58 | 5.93 |
| fisheye_projectPoints | fproj_zero_rot | 0.00 | 0.01 | 0.26 **faster** |
| fisheye_initUndistortRectifyMap | frectmap_small | 0.02 | 0.02 | 1.07 |
| solvePnPRansac | pnp_ransac_pl | 0.44 | 0.32 | 1.36 |
| flip | flip_y_odd | 0.01 | 0.00 | n/a |
| flip | flip_xy_one | 0.01 | 0.00 | n/a |
| flip | flip_y_f32 | 0.01 | 0.00 | n/a |
| rotate | rotate_180_odd | 0.01 | 0.00 | n/a |
| rotate | rotate_ccw_i16 | 0.01 | 0.00 | n/a |
| transpose | transpose_i32 | 0.23 | 0.00 | n/a |
| absdiff | absdiff_g1 | 0.01 | 0.00 | n/a |
| absdiff | absdiff_i16 | 0.01 | 0.00 | n/a |
| absdiff | absdiff_f32 | 0.01 | 0.00 | n/a |
| bitwise_or | bitwise_or_odd | 0.01 | 0.00 | n/a |
| bitwise_xor | bitwise_xor_f32 | 0.22 | 0.00 | n/a |
| bitwise_not | bitwise_not_one | 0.22 | 0.00 | n/a |
| convert | convert_f32_u8_half | 0.01 | 0.01 | 1.25 |
| convert | convert_f32_i16_scale | 0.01 | 0.01 | 1.15 |
| convert | convert_f64_i32 | 0.01 | 0.01 | 1.15 |
| convert | convert_u8_u8_one | 0.01 | 0.01 | 1.37 |
| bitwise_and | bitwise_and_odd | 0.01 | 0.00 | n/a |
| bitwise_xor | bitwise_xor_i16 | 0.01 | 0.00 | n/a |
| bfmatch | bf_ab | 0.83 | 0.16 | 5.05 |
| bfmatch | bf_one | 0.03 | 0.01 | 4.43 |
| bfmatch | bf_self | 0.60 | 0.15 | 4.09 |
| knnmatch | knn_ab | 0.81 | 0.28 | 2.85 |
| knnmatch | knn_ratio_tight | 0.85 | 0.29 | 2.90 |
| ORB | orb_sm | 10.81 | 1.88 | 5.76 |
| ORB | orb_blank | 4.75 | 0.03 | 171.15 |
| GaussianBlur | gauss7_odd | 0.04 | 0.01 | 7.40 |
| GaussianBlur | gauss_f32 | 0.03 | 0.00 | n/a |
| GaussianBlur | gauss3_one | 0.03 | 0.00 | n/a |
| pyrDown | pyrdown_odd | 0.03 | 0.00 | n/a |
| pyrDown | pyrdown_one | 0.03 | 0.00 | n/a |
| pyrDown | pyrdown_f32 | 0.03 | 0.00 | n/a |
| Sobel | sobel_scharr_g1 | 0.03 | 0.00 | n/a |
| Sobel | sobel_f32_dxx | 0.03 | 0.00 | n/a |
| threshold | thresh_inv_sm | 0.02 | 0.01 | 1.90 |
| threshold | thresh_trunc_g1 | 0.01 | 0.00 | n/a |
| threshold | thresh_tozero_g1 | 0.01 | 0.00 | n/a |
| threshold | thresh_otsu_one | 0.01 | 0.00 | n/a |
| threshold | thresh_f32 | 0.01 | 0.00 | n/a |
| integral | integral_odd | 0.02 | 0.00 | n/a |
| integral | integral_f32 | 0.02 | 0.00 | n/a |
| integral | integral_one | 0.02 | 0.00 | n/a |
| dilate | dilate_cross_sm | 0.12 | 0.07 | 1.82 |
| dilate | dilate_ell_smg | 0.13 | 0.08 | 1.54 |
| erode | erode_ell_odd | 0.02 | 0.00 | n/a |
| dilate | dilate_one | 0.03 | 0.00 | n/a |
| erode | erode_f32 | 0.03 | 0.00 | n/a |
| cvtColor | cvt_rgb2gray_odd | 0.01 | 0.00 | n/a |
| cvtColor | cvt_gray2bgr_g1 | 0.01 | 0.00 | n/a |
| cvtColor | cvt_hsv_odd | 0.01 | 0.00 | n/a |
| cvtColor | cvt_hsv_one | 0.01 | 0.00 | n/a |
| cvtColor | cvt_hsv2bgr_odd | 0.01 | 0.00 | n/a |
| cvtColor | cvt_ycrcb2bgr_sm | 0.13 | 0.04 | 2.99 |
| cvtColor | cvt_gray_f32 | 0.22 | 0.00 | n/a |
| resize | resize_up_lin_sm | 0.72 | 0.17 | 4.16 |
| resize | resize_nn_odd | 0.02 | 0.00 | n/a |
| resize | resize_cub_sm | 0.74 | 0.09 | 7.87 |
| resize | resize_lan_sm | 0.50 | 1.56 | 0.32 **faster** |
| resize | resize_lin_one | 0.02 | 0.00 | n/a |
| resize | resize_lin_f32 | 0.02 | 0.00 | n/a |
| warpAffine | warp_nn_sm | 0.51 | 0.03 | 20.26 |
| warpAffine | warp_cub_smg | 0.90 | 0.08 | 11.60 |
| warpAffine | warp_rep_odd | 0.01 | 0.01 | 1.25 |
| warpAffine | warp_inv_g1 | 0.01 | 0.01 | 1.47 |
| warpAffine | warp_f32 | 0.01 | 0.01 | 1.27 |
| remap | remap_nn_sm | 0.40 | 0.04 | 9.99 |
| remap | remap_cub_smg | 0.69 | 0.10 | 7.03 |
| remap | remap_odd_const | 0.01 | 0.00 | n/a |
| remap | remap_odd_refl | 0.01 | 0.00 | n/a |
| blobFromImage | blob_sm | 0.55 | 0.24 | 2.27 |
| connectedComponentsWithStats | ccl8_bin | 1.37 | 0.31 | 4.40 |
| connectedComponentsWithStats | ccl4_binhd | 19.81 | 8.58 | 2.31 |
| connectedComponentsWithStats | ccl8_shapes | 0.04 | 0.02 | 1.72 |
| connectedComponentsWithStats | ccl_blank | 0.00 | 0.00 | n/a |
| Canny | canny_smg_l2 | 0.64 | 0.10 | 6.55 |
| Canny | canny_sm5 | 0.66 | 0.17 | 3.81 |
| Canny | canny_blank | 6.51 | 0.01 | 729.40 |
| Canny | canny_g1 | 0.08 | 0.01 | 9.57 |
| findContours | contours_ext_shapes | 0.02 | 0.02 | 0.98 **faster** |
| findContours | contours_list_shapes | 0.02 | 0.02 | 0.85 **faster** |
| findContours | contours_simple_shapes | 0.02 | 0.02 | 0.93 **faster** |
| findContours | contours_ext_bin | 0.42 | 0.06 | 6.93 |
| findContours | contours_list_bin | 0.46 | 0.28 | 1.65 |
| findContours | contours_blank | 0.00 | 0.00 | n/a |
| findContours | contours_full | 0.00 | 0.01 | 0.18 **faster** |
| goodFeaturesToTrack | gftt_smg | 27.22 | 2.74 | 9.94 |
| goodFeaturesToTrack | gftt_blank | 12.45 | 0.01 | 1237.62 |
| line | line_steep_g1 | 0.00 | 0.00 | n/a |
| line | line_clip_sm | 0.01 | 0.01 | 0.69 **faster** |
| line | line_out_sm | 0.01 | 0.01 | 0.54 **faster** |
| line | line_hor_odd | 0.00 | 0.00 | n/a |
| rectangle | rect_edge_sm | 0.01 | 0.01 | 0.70 **faster** |
| rectangle | rect_fill_odd | 0.00 | 0.00 | n/a |
| HOGScores | hog_scores_smg | 4.66 | 12.11 | 0.39 **faster** |
| detectMultiScale | hog_raw_smg | 49.34 | 4.09 | 12.07 |
| detectMultiScale | hog_group_smg | 46.23 | 4.23 | 10.92 |
| detectMultiScale | hog_group_smg2 | 49.40 | 4.29 | 11.51 |
| detectMultiScale | hog_none | 46.28 | 3.75 | 12.35 |
| groupRectangles | group_rects_hdg | 0.98 | 1.48 | 0.67 **faster** |
| grabCut | grabcut_scene | 36.75 | 9.75 | 3.77 |
| grabCut | grabcut_shot | 55.12 | 10.19 | 5.41 |
| grabCut | grabcut_tiny | 0.10 | 0.07 | 1.43 |
| cornerSubPix | subpix_sm | 1.40 | 0.56 | 2.47 |
| cornerSubPix | subpix_win3 | 0.74 | 0.37 | 1.99 |
| cornerSubPix | subpix_edge | 2.88 | 0.93 | 3.12 |
| calcOpticalFlowPyrLK | lk_sm | 9.82 | 0.26 | 38.35 |
| calcOpticalFlowPyrLK | lk_sm_win9 | 5.68 | 0.13 | 44.73 |
| calcOpticalFlowFarneback | fb_shift | 26.48 | 17.73 | 1.49 |
| calcOpticalFlowFarneback | fb_frames | 27.74 | 18.35 | 1.51 |
| calcOpticalFlowFarneback | fb_poly7 | 22.44 | 17.62 | 1.27 |
| calcOpticalFlowFarneback | fb_tiny | 1.30 | 0.01 | 98.18 |
