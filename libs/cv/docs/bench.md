# L2D speed rows: mojo-cv vs cv2 5.0

Method: `tests/run.sh --bench-all --md docs/bench.md`. Each row runs the same op in one resident process with `reps=5`
and keeps the best wall time of the compute only (file load and save excluded), ours via `.bin/mojo-cv`, cv2 via
`tools/oracle_cv2.py` (numpy in, cv2 call, best of 5). Both sides use all threads of the 7800X3D; CPU only, no GPU.
Inputs are the same `.mcv` fixtures (`hd*` = 1920x1080 crops of a real screenshot, the rest smaller). Target from
`docs/provenance/2d.md`: ours <= cv2. **Misses are listed as measured; nothing is hidden.** The HOG rows time cv2 4.8.1
(cv2 5.0 has no HOG).

1080p rows: 22 of 46 faster than cv2, 8 more within 1.5x, the rest slower (ratio column).

- **Parallel dispatch**: `max.algorithm.parallelize` with the default 16 workers costs about 215 us per region (best of
  50 trivial regions); with 8 workers (the physical cores) it costs about 8 us, so `core.par` uses 8 and takes 16 only for
  regions that run for milliseconds. A cached CPU DeviceContext changed nothing. Allocating and zero-filling a 2 MB `Mat`
  is 18 us. Probes: measured in a scratch build, numbers quoted in the lane report.
- Lane f2 (2026-10-22) rewrote the loops behind erode/dilate, GaussianBlur, Sobel, pyrDown, resize, warpAffine, remap,
  blobFromImage, Canny, goodFeaturesToTrack, ORB FAST and HOG on raw row pointers with SIMD and per-worker cached
  scratch (commits 3cca268 .. 060c3e0). Lane f34 added Lab/Luv, INTER_AREA, Harris, THRESH_TRIANGLE and thick lines
  with the same pattern. Same-session old/new/cv2 timings (min of 5, interleaved, `tools/abbench.py`) are in
  `exchange/lane-f2-report.md`.
- **Read the ratios with care.** This box also runs other lanes' jobs; the same row moves by a factor of two between
  two runs of this table (a quiet run and a loaded run of the same binary are both kept in the lane report). Rows that
  sit near 1.0 can land on either side. `tools/abbench.py` runs old, new and cv2 back to back per row, which is the
  fair comparison under load.
- Still slower than cv2 on 1080p in the latest run: flip, pyrDown, 8-bit threshold (cv2 reaches ~25 GB/s on a 2 MB
  plane), the colour conversions (swap, HSV, YCrCb, Lab, Luv), resize shrink and nearest, remap, Canny (the hysteresis
  flood is serial) and warpAffine in quiet runs. HOG detection, ORB, goodFeaturesToTrack, blobFromImage, Otsu,
  Triangle, area resize and `convert` beat cv2.
- Point-set ops (projectPoints, estimateAffine2D, stereoRectify) take microseconds on both sides; 0.00 ms entries are
  below the timer's resolution, not a result.

## 1920x1080 rows

| op | row | ours ms | cv2 ms | ours/cv2 |
|---|---|---:|---:|---:|
| flip | flip_x_hd | 0.75 | 0.15 | 5.18 |
| rotate | rotate_cw_hd | 1.38 | 1.13 | 1.22 |
| transpose | transpose_hd | 0.21 | 0.13 | 1.57 |
| absdiff | absdiff_hd | 0.15 | 0.23 | 0.68 **faster** |
| bitwise_and | bitwise_and_hd | 0.12 | 0.24 | 0.50 **faster** |
| bitwise_not | bitwise_not_hd | 0.10 | 0.16 | 0.61 **faster** |
| convert | convert_u8_f32_hd | 0.38 | 15.69 | 0.02 **faster** |
| bitwise_or | bitwise_or_hd | 0.35 | 0.22 | 1.59 |
| bitwise_xor | bitwise_xor_hd | 0.13 | 0.23 | 0.54 **faster** |
| ORB | orb_hd | 12.45 | 18.45 | 0.67 **faster** |
| GaussianBlur | gauss5_hd | 1.40 | 1.36 | 1.03 |
| GaussianBlur | gauss_s2_hdg | 0.79 | 1.71 | 0.46 **faster** |
| pyrDown | pyrdown_hd | 1.05 | 0.33 | 3.23 |
| Sobel | sobel_dx_hdg | 0.23 | 0.20 | 1.14 |
| Sobel | sobel_dy5_hd | 1.40 | 2.10 | 0.67 **faster** |
| threshold | thresh_bin_hdg | 0.27 | 0.04 | 6.54 |
| threshold | thresh_tozinv_hd | 0.10 | 0.06 | 1.72 |
| threshold | thresh_otsu_hdg | 0.05 | 1.09 | 0.05 **faster** |
| threshold | thresh_tri_hdg | 0.05 | 0.91 | 0.05 **faster** |
| integral | integral_hdg | 0.48 | 0.34 | 1.39 |
| integral | integral_hd | 1.31 | 1.72 | 0.76 **faster** |
| erode | erode_hdg | 0.10 | 0.52 | 0.19 **faster** |
| erode | erode_hd5 | 0.30 | 0.25 | 1.19 |
| cvtColor | cvt_gray_hd | 0.12 | 0.10 | 1.28 |
| cvtColor | cvt_swap_hd | 0.33 | 0.08 | 4.14 |
| cvtColor | cvt_hsv_hd | 2.19 | 0.61 | 3.61 |
| cvtColor | cvt_ycrcb_hd | 0.57 | 0.92 | 0.62 **faster** |
| cvtColor | cvt_lab_hd | 2.51 | 1.17 | 2.15 |
| cvtColor | cvt_luv_hd | 2.04 | 1.24 | 1.65 |
| resize | resize_down_lin_hd | 0.48 | 0.09 | 5.23 |
| resize | resize_nn_hd | 0.18 | 0.07 | 2.52 |
| resize | resize_cub_hdg | 0.25 | 0.12 | 2.14 |
| resize | resize_lan_hdg | 5.55 | 3.63 | 1.53 |
| resize | resize_area_hd | 0.56 | 1.58 | 0.35 **faster** |
| resize | resize_area_frac | 0.76 | 3.15 | 0.24 **faster** |
| warpAffine | warp_rot_hd | 2.41 | 3.52 | 0.68 **faster** |
| remap | remap_lin_hd | 2.53 | 1.12 | 2.26 |
| blobFromImage | blob_hd | 0.14 | 0.30 | 0.48 **faster** |
| Canny | canny_hdg | 2.81 | 1.00 | 2.80 |
| goodFeaturesToTrack | gftt_hdg | 3.36 | 22.82 | 0.15 **faster** |
| goodFeaturesToTrack | gftt_harris_hdg | 2.54 | 25.70 | 0.10 **faster** |
| line | line_diag_hd | 0.17 | 0.14 | 1.26 |
| line | line_thick_hd | 0.20 | 0.16 | 1.21 |
| HOGScores | hog_scores_hdg | 3.49 | 347.93 | 0.01 **faster** |
| detectMultiScale | hog_raw_hdg | 44.39 | 84.82 | 0.52 **faster** |
| detectMultiScale | hog_group_hdg | 45.96 | 82.23 | 0.56 **faster** |

## Other sizes (270x480 and smaller, point sets, stereo pairs)

| op | row | ours ms | cv2 ms | ours/cv2 |
|---|---|---:|---:|---:|
| Rodrigues | rod_vec | 0.00 | 0.00 | n/a |
| Rodrigues | rod_zero | 0.00 | 0.00 | n/a |
| Rodrigues | rod_mat | 0.01 | 0.00 | n/a |
| Rodrigues | rod_mat_pi | 0.00 | 0.00 | n/a |
| Rodrigues | rod_mat_id | 0.00 | 0.00 | n/a |
| projectPoints | proj_d4 | 0.00 | 0.01 | 0.17 **faster** |
| projectPoints | proj_d5 | 0.00 | 0.01 | 0.16 **faster** |
| projectPoints | proj_d8 | 0.00 | 0.01 | 0.21 **faster** |
| projectPoints | proj_d12 | 0.00 | 0.01 | 0.13 **faster** |
| projectPoints | proj_nodist | 0.00 | 0.01 | 0.12 **faster** |
| fisheye_projectPoints | fproj | 0.00 | 0.01 | 0.27 **faster** |
| undistortPoints | undist_d4 | 0.00 | 0.00 | n/a |
| undistortPoints | undist_d8 | 0.00 | 0.00 | n/a |
| undistortPoints | undist_rp | 0.00 | 0.01 | 0.45 **faster** |
| undistortPoints | undist_zero | 0.00 | 0.00 | n/a |
| fisheye_undistortPoints | fundist | 0.00 | 0.00 | n/a |
| fisheye_undistortPoints | fundist_rp | 0.00 | 0.00 | n/a |
| initUndistortRectifyMap | rectmap_d5 | 2.13 | 0.31 | 6.93 |
| initUndistortRectifyMap | rectmap_id | 0.03 | 0.01 | 3.72 |
| fisheye_initUndistortRectifyMap | frectmap | 0.60 | 1.25 | 0.48 **faster** |
| estimateAffine2D | aff_ransac | 0.02 | 0.03 | 0.62 **faster** |
| estimateAffine2D | aff_tight | 0.02 | 0.03 | 0.56 **faster** |
| solvePnP | pnp_d4 | 0.22 | 0.06 | 3.48 |
| solvePnP | pnp_planar | 0.08 | 0.08 | 0.96 **faster** |
| solvePnP | pnp_nodist | 0.35 | 0.09 | 3.79 |
| solvePnPRansac | pnp_ransac | 5.34 | 0.99 | 5.37 |
| findEssentialMat | ess_ransac | 13.13 | 2.31 | 5.68 |
| stereoRectify | rect_zero | 0.01 | 0.02 | 0.37 **faster** |
| stereoRectify | rect_dist | 0.01 | 0.02 | 0.35 **faster** |
| stereoRectify | rect_nozd | 0.01 | 0.02 | 0.42 **faster** |
| findEssentialMat | ess_noisy | 11.35 | 2.77 | 4.09 |
| recoverPose | pose_masked | 0.70 | 0.23 | 3.05 |
| recoverPose | pose_all | 1.10 | 0.21 | 5.17 |
| StereoSGBM | sgbm_dots | 8.62 | 2.35 | 3.67 |
| StereoSGBM | sgbm_block3 | 8.05 | 2.29 | 3.52 |
| StereoSGBM | sgbm_mind | 5.55 | 1.84 | 3.01 |
| findChessboardCorners | chess_a | 0.71 | 0.78 | 0.90 **faster** |
| findChessboardCorners | chess_b_rot | 0.61 | 0.90 | 0.67 **faster** |
| findChessboardCorners | chess_c | 0.60 | 3.95 | 0.15 **faster** |
| findChessboardCorners | chess_none | 7.46 | 11.13 | 0.67 **faster** |
| aruco_detect | aruco_four | 6.92 | 1.23 | 5.62 |
| aruco_detect | aruco_persp | 2.33 | 0.56 | 4.19 |
| aruco_detect | aruco_none | 2.04 | 0.62 | 3.29 |
| fisheye_projectPoints | fproj_zero_rot | 0.00 | 0.01 | 0.25 **faster** |
| fisheye_initUndistortRectifyMap | frectmap_small | 0.02 | 0.02 | 1.01 |
| solvePnPRansac | pnp_ransac_pl | 0.54 | 0.32 | 1.67 |
| solvePnP | pnp_epnp_four | 0.28 | 0.07 | 3.87 |
| solvePnP | pnp_epnp_noise | 0.48 | 0.10 | 4.61 |
| findEssentialMat | ess_five_minimal | 0.50 | 0.16 | 3.14 |
| findEssentialMat | ess_five_clean | 0.60 | 0.16 | 3.71 |
| findEssentialMat | ess_five_roots | 0.46 | 0.19 | 2.50 |
| stereoRectify | rect_alpha0 | 0.02 | 0.02 | 0.79 **faster** |
| stereoRectify | rect_alpha1 | 0.02 | 0.02 | 0.81 **faster** |
| stereoRectify | rect_vertical | 0.01 | 0.02 | 0.35 **faster** |
| stereoRectify | rect_vertical_a | 0.02 | 0.02 | 0.80 **faster** |
| flip | flip_y_odd | 0.01 | 0.00 | n/a |
| flip | flip_xy_one | 0.01 | 0.00 | n/a |
| flip | flip_y_f32 | 0.23 | 0.00 | n/a |
| rotate | rotate_180_odd | 0.01 | 0.00 | n/a |
| rotate | rotate_ccw_i16 | 0.01 | 0.00 | n/a |
| transpose | transpose_i32 | 0.01 | 0.00 | n/a |
| absdiff | absdiff_g1 | 0.01 | 0.00 | n/a |
| absdiff | absdiff_i16 | 0.43 | 0.00 | n/a |
| absdiff | absdiff_f32 | 0.01 | 0.00 | n/a |
| bitwise_or | bitwise_or_odd | 0.01 | 0.00 | n/a |
| bitwise_xor | bitwise_xor_f32 | 0.22 | 0.00 | n/a |
| bitwise_not | bitwise_not_one | 0.01 | 0.00 | n/a |
| convert | convert_f32_u8_half | 0.01 | 0.01 | 1.52 |
| convert | convert_f32_i16_scale | 0.01 | 0.01 | 1.08 |
| convert | convert_f64_i32 | 0.01 | 0.01 | 1.23 |
| convert | convert_u8_u8_one | 0.25 | 0.01 | 26.36 |
| bitwise_and | bitwise_and_odd | 0.01 | 0.00 | n/a |
| bitwise_xor | bitwise_xor_i16 | 0.01 | 0.00 | n/a |
| bfmatch | bf_ab | 0.82 | 0.17 | 4.69 |
| bfmatch | bf_one | 0.03 | 0.01 | 4.88 |
| bfmatch | bf_self | 0.61 | 0.17 | 3.65 |
| knnmatch | knn_ab | 0.84 | 0.35 | 2.43 |
| knnmatch | knn_ratio_tight | 2.21 | 0.31 | 7.04 |
| ORB | orb_sm | 2.62 | 1.86 | 1.41 |
| ORB | orb_blank | 0.26 | 0.03 | 9.40 |
| GaussianBlur | gauss7_odd | 0.01 | 0.01 | 1.97 |
| GaussianBlur | gauss_f32 | 0.01 | 0.00 | n/a |
| GaussianBlur | gauss3_one | 0.01 | 0.00 | n/a |
| pyrDown | pyrdown_odd | 0.01 | 0.00 | n/a |
| pyrDown | pyrdown_one | 0.01 | 0.00 | n/a |
| pyrDown | pyrdown_f32 | 0.01 | 0.00 | n/a |
| Sobel | sobel_scharr_g1 | 0.01 | 0.00 | n/a |
| Sobel | sobel_f32_dxx | 0.02 | 0.00 | n/a |
| threshold | thresh_inv_sm | 0.01 | 0.01 | 1.55 |
| threshold | thresh_trunc_g1 | 0.01 | 0.00 | n/a |
| threshold | thresh_tozero_g1 | 0.01 | 0.00 | n/a |
| threshold | thresh_otsu_one | 0.01 | 0.00 | n/a |
| threshold | thresh_tri_bin | 0.01 | 0.06 | 0.24 **faster** |
| threshold | thresh_tri_blank | 0.01 | 0.00 | n/a |
| threshold | thresh_tri_g2 | 0.01 | 0.00 | n/a |
| threshold | thresh_f32 | 0.01 | 0.00 | n/a |
| integral | integral_odd | 0.24 | 0.00 | n/a |
| integral | integral_f32 | 0.01 | 0.00 | n/a |
| integral | integral_one | 0.01 | 0.00 | n/a |
| dilate | dilate_cross_sm | 0.12 | 0.07 | 1.78 |
| dilate | dilate_ell_smg | 0.11 | 0.08 | 1.28 |
| erode | erode_ell_odd | 0.02 | 0.00 | n/a |
| dilate | dilate_one | 0.44 | 0.00 | n/a |
| erode | erode_f32 | 0.02 | 0.00 | n/a |
| cvtColor | cvt_rgb2gray_odd | 0.01 | 0.00 | n/a |
| cvtColor | cvt_gray2bgr_g1 | 0.01 | 0.00 | n/a |
| cvtColor | cvt_hsv_odd | 0.01 | 0.00 | n/a |
| cvtColor | cvt_hsv_one | 0.23 | 0.00 | n/a |
| cvtColor | cvt_hsv2bgr_odd | 0.01 | 0.00 | n/a |
| cvtColor | cvt_ycrcb2bgr_sm | 0.11 | 0.04 | 2.66 |
| cvtColor | cvt_gray_f32 | 0.01 | 0.00 | n/a |
| cvtColor | cvt_lab_one | 0.19 | 0.00 | n/a |
| cvtColor | cvt_lab_f32 | 0.22 | 0.00 | n/a |
| cvtColor | cvt_lab2bgr_sm | 0.36 | 0.39 | 0.90 **faster** |
| cvtColor | cvt_lab2bgr_one | 0.22 | 0.00 | n/a |
| cvtColor | cvt_luv_odd | 0.24 | 0.00 | n/a |
| cvtColor | cvt_luv_f32 | 0.21 | 0.00 | n/a |
| cvtColor | cvt_luv2bgr_sm | 0.37 | 0.33 | 1.12 |
| cvtColor | cvt_luv2bgr_f32 | 0.35 | 0.24 | 1.49 |
| cvtColor | cvt_lab2bgr_f32 | 0.35 | 0.32 | 1.10 |
| resize | resize_up_lin_sm | 0.28 | 0.15 | 1.84 |
| resize | resize_nn_odd | 0.01 | 0.00 | n/a |
| resize | resize_cub_sm | 0.38 | 0.10 | 3.74 |
| resize | resize_lan_sm | 0.37 | 1.63 | 0.23 **faster** |
| resize | resize_lin_one | 0.01 | 0.00 | n/a |
| resize | resize_lin_f32 | 0.02 | 0.00 | n/a |
| resize | resize_area_up2 | 0.56 | 0.34 | 1.66 |
| resize | resize_area_shrinkx | 1.12 | 0.43 | 2.60 |
| resize | resize_area_up | 0.37 | 0.16 | 2.25 |
| resize | resize_area_odd | 0.01 | 0.00 | n/a |
| resize | resize_area_one | 0.44 | 0.00 | n/a |
| resize | resize_area_f32 | 0.01 | 0.00 | n/a |
| warpAffine | warp_nn_sm | 0.50 | 0.15 | 3.27 |
| warpAffine | warp_cub_smg | 0.87 | 0.13 | 6.69 |
| warpAffine | warp_rep_odd | 0.01 | 0.01 | 1.02 |
| warpAffine | warp_inv_g1 | 0.01 | 0.01 | 1.26 |
| warpAffine | warp_f32 | 0.01 | 0.01 | 1.30 |
| remap | remap_nn_sm | 0.38 | 0.06 | 6.93 |
| remap | remap_cub_smg | 0.79 | 0.29 | 2.75 |
| remap | remap_odd_const | 0.01 | 0.00 | n/a |
| remap | remap_odd_refl | 0.01 | 0.01 | 1.83 |
| blobFromImage | blob_sm | 0.59 | 0.23 | 2.56 |
| connectedComponentsWithStats | ccl8_bin | 1.41 | 0.33 | 4.28 |
| connectedComponentsWithStats | ccl4_binhd | 21.82 | 2.33 | 9.36 |
| connectedComponentsWithStats | ccl8_shapes | 0.04 | 0.02 | 1.81 |
| connectedComponentsWithStats | ccl_blank | 0.00 | 0.00 | n/a |
| Canny | canny_smg_l2 | 0.25 | 0.08 | 3.30 |
| Canny | canny_sm5 | 0.21 | 0.17 | 1.30 |
| Canny | canny_blank | 0.04 | 0.01 | 3.24 |
| Canny | canny_g1 | 0.04 | 0.01 | 4.47 |
| findContours | contours_ext_shapes | 0.02 | 0.02 | 0.98 **faster** |
| findContours | contours_list_shapes | 0.02 | 0.02 | 0.83 **faster** |
| findContours | contours_simple_shapes | 0.02 | 0.02 | 0.82 **faster** |
| findContours | contours_ext_bin | 0.45 | 0.07 | 6.09 |
| findContours | contours_list_bin | 0.48 | 0.27 | 1.79 |
| findContours | contours_blank | 0.00 | 0.00 | n/a |
| findContours | contours_full | 0.00 | 0.01 | 0.17 **faster** |
| findContours | contours_ccomp_shapes | 0.02 | 0.02 | 0.83 **faster** |
| findContours | contours_tree_shapes | 0.02 | 0.02 | 0.86 **faster** |
| findContours | contours_tree_simple | 0.02 | 0.02 | 0.85 **faster** |
| findContours | contours_ccomp_bin | 0.47 | 0.25 | 1.90 |
| findContours | contours_tree_bin | 0.48 | 0.30 | 1.60 |
| findContours | contours_tree_binhd | 7.95 | 6.24 | 1.28 |
| findContours | contours_tree_blank | 0.00 | 0.00 | n/a |
| findContours | contours_tree_full | 0.00 | 0.01 | 0.17 **faster** |
| goodFeaturesToTrack | gftt_smg | 0.27 | 1.69 | 0.16 **faster** |
| goodFeaturesToTrack | gftt_blank | 0.08 | 0.01 | 7.14 |
| goodFeaturesToTrack | gftt_harris_smg | 0.25 | 1.85 | 0.13 **faster** |
| goodFeaturesToTrack | gftt_harris_blank | 0.08 | 0.01 | 7.22 |
| line | line_steep_g1 | 0.00 | 0.00 | n/a |
| line | line_clip_sm | 0.01 | 0.01 | 0.70 **faster** |
| line | line_out_sm | 0.01 | 0.01 | 0.53 **faster** |
| line | line_thick_g1 | 0.00 | 0.00 | n/a |
| line | line_thick_flat | 0.02 | 0.01 | 1.12 |
| line | line_thick_dot | 0.01 | 0.01 | 0.63 **faster** |
| line | line_thick_clip | 0.02 | 0.02 | 1.29 |
| rectangle | rect_thick_sm | 0.04 | 0.02 | 1.65 |
| line | line_hor_odd | 0.00 | 0.00 | n/a |
| rectangle | rect_edge_sm | 0.01 | 0.01 | 0.85 **faster** |
| rectangle | rect_fill_odd | 0.00 | 0.00 | n/a |
| HOGScores | hog_scores_smg | 0.26 | 10.28 | 0.03 **faster** |
| detectMultiScale | hog_raw_smg | 2.84 | 3.50 | 0.81 **faster** |
| detectMultiScale | hog_group_smg | 2.83 | 3.93 | 0.72 **faster** |
| detectMultiScale | hog_group_smg2 | 3.08 | 3.30 | 0.94 **faster** |
| detectMultiScale | hog_none | 3.95 | 4.29 | 0.92 **faster** |
| groupRectangles | group_rects_hdg | 1.02 | 1.52 | 0.67 **faster** |
| grabCut | grabcut_scene | 38.12 | 9.28 | 4.11 |
| grabCut | grabcut_shot | 59.05 | 9.47 | 6.23 |
| grabCut | grabcut_tiny | 0.10 | 0.07 | 1.44 |
| findChessboardCorners | chess_real_0 | 1.19 | 2.40 | 0.50 **faster** |
| findChessboardCorners | chess_real_1 | 1.17 | 2.57 | 0.46 **faster** |
| findChessboardCorners | chess_real_2 | 1.02 | 2.49 | 0.41 **faster** |
| findChessboardCorners | chess_real_3 | 1.15 | 2.29 | 0.50 **faster** |
| findChessboardCorners | chess_real_4 | 1.16 | 2.17 | 0.53 **faster** |
| aruco_detect | aruco_real_0 | 6.44 | 1.80 | 3.58 |
| aruco_detect | aruco_real_1 | 6.36 | 0.99 | 6.41 |
| aruco_detect | aruco_real_2 | 6.45 | 0.93 | 6.95 |
| aruco_detect | aruco_real_3 | 6.33 | 0.89 | 7.11 |
| aruco_detect | aruco_real_4 | 6.36 | 1.03 | 6.18 |
| solvePnP | pnp_real_0 | 0.68 | 0.18 | 3.74 |
| solvePnP | pnp_real_1 | 0.58 | 0.19 | 3.11 |
| solvePnP | pnp_real_2 | 0.82 | 0.19 | 4.33 |
| solvePnP | pnp_real_3 | 0.82 | 0.19 | 4.39 |
| solvePnP | pnp_real_4 | 0.99 | 0.19 | 5.28 |
| ORB | orb_real_0 | 5.18 | 4.92 | 1.05 |
| cornerSubPix | subpix_sm | 1.36 | 0.57 | 2.40 |
| cornerSubPix | subpix_win3 | 0.74 | 0.38 | 1.98 |
| cornerSubPix | subpix_edge | 2.87 | 1.13 | 2.54 |
| calcOpticalFlowPyrLK | lk_sm | 9.15 | 0.29 | 31.99 |
| calcOpticalFlowPyrLK | lk_sm_win9 | 5.40 | 0.13 | 40.38 |
| calcOpticalFlowFarneback | fb_shift | 24.11 | 18.08 | 1.33 |
| calcOpticalFlowFarneback | fb_frames | 28.44 | 17.70 | 1.61 |
| calcOpticalFlowFarneback | fb_poly7 | 20.12 | 18.05 | 1.11 |
| calcOpticalFlowFarneback | fb_tiny | 1.58 | 0.01 | 109.24 |
