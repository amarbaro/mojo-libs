# L2D speed rows: mojo-cv vs cv2 5.0

Method: `tests/run.sh --bench-all`. Each row runs the same op in one resident process with `reps=5` and keeps the best
wall time of the compute only (file load and save excluded), ours via `.bin/mojo-cv`, cv2 via `tools/oracle_cv2.py`
(numpy in, cv2 call, best of 5). Both sides use all 16 threads of the 7800X3D; CPU only, no GPU. Inputs are the same
`.mcv` fixtures (`hd*` = 1920x1080 crops of a real screenshot, the rest smaller). Target from `docs/provenance/2d.md`:
ours <= cv2. **Misses are listed as measured; nothing is hidden.** The HOG rows time cv2 4.8.1 (cv2 5.0 has no HOG).

Result on the 1080p rows: 6 of 41 are faster than cv2, 3 more are within 1.5x, the rest are slower
(ratio column). Where the time goes, measured in `.work/probe/` on this machine, not assumed:

- **Parallel dispatch costs about 215 us per region** through `max.algorithm.parallelize` and `sync_parallelize`
  (best of 50 trivial 16-task regions; a cached CPU DeviceContext changed nothing, so it is the runtime's wake-up).
  Most ops here run two or three regions (pad, row pass, column pass), so 0.4 to 0.7 ms of a 1080p op is dispatch
  where cv2 finishes the whole op in 0.05 to 0.3 ms. Allocating and zero-filling a 2 MB `Mat` is only 18 us.
  A spinning pthread pool (pattern of `mojo-baro/serve/cpu_worker.mojo`) would remove most of it; storing a
  type-erased trampoline in a struct crashed (segfault on the indirect call), so the pool was not built.
- The stencil, warp, remap, Canny and LK loops are scalar per-pixel code with `Mat.at` bounds checks and are not tuned
  (warp/remap 13x, Canny 13x, LK 36x); cv2's are hand-vectorised.
- Faster than cv2 on 1080p: `convert` u8 to f32 (cv2's path is slow), Otsu threshold, `line`, HOG window scoring at one
  scale, `groupRectangles`; `rotate` ties. Point-set ops (projectPoints, estimateAffine2D, stereoRectify) are microseconds
  on both sides and the 0.00 ms entries are below the timer's resolution, not a result.

## 1920x1080 rows

| op | row | ours ms | cv2 ms | ours/cv2 |
|---|---|---:|---:|---:|
| flip | flip_x_hd | 0.60 | 0.13 | 4.62 |
| rotate | rotate_cw_hd | 1.25 | 1.26 | 0.99 **faster** |
| transpose | transpose_hd | 0.46 | 0.13 | 3.54 |
| absdiff | absdiff_hd | 0.33 | 0.25 | 1.32 |
| bitwise_and | bitwise_and_hd | 0.31 | 0.23 | 1.35 |
| bitwise_not | bitwise_not_hd | 0.30 | 0.17 | 1.76 |
| convert | convert_u8_f32_hd | 0.55 | 10.90 | 0.05 **faster** |
| bitwise_or | bitwise_or_hd | 0.35 | 0.21 | 1.67 |
| bitwise_xor | bitwise_xor_hd | 0.34 | 0.22 | 1.55 |
| ORB | orb_hd | 53.78 | 12.91 | 4.17 |
| GaussianBlur | gauss5_hd | 2.17 | 0.31 | 7.00 |
| GaussianBlur | gauss_s2_hdg | 1.40 | 0.47 | 2.98 |
| pyrDown | pyrdown_hd | 3.75 | 0.28 | 13.39 |
| Sobel | sobel_dx_hdg | 1.21 | 0.12 | 10.08 |
| Sobel | sobel_dy5_hd | 2.07 | 1.18 | 1.75 |
| threshold | thresh_bin_hdg | 0.26 | 0.02 | 13.00 |
| threshold | thresh_tozinv_hd | 0.31 | 0.04 | 7.75 |
| threshold | thresh_otsu_hdg | 0.25 | 1.07 | 0.23 **faster** |
| integral | integral_hdg | 1.31 | 0.35 | 3.74 |
| integral | integral_hd | 3.22 | 1.60 | 2.01 |
| erode | erode_hdg | 0.96 | 0.07 | 13.71 |
| erode | erode_hd5 | 3.12 | 0.17 | 18.35 |
| cvtColor | cvt_gray_hd | 0.82 | 0.06 | 13.67 |
| cvtColor | cvt_swap_hd | 1.05 | 0.05 | 21.00 |
| cvtColor | cvt_hsv_hd | 1.45 | 0.36 | 4.03 |
| cvtColor | cvt_ycrcb_hd | 1.64 | 0.14 | 11.71 |
| resize | resize_down_lin_hd | 2.14 | 0.11 | 19.45 |
| resize | resize_nn_hd | 0.87 | 0.08 | 10.88 |
| resize | resize_cub_hdg | 1.02 | 0.11 | 9.27 |
| resize | resize_lan_hdg | 3.41 | 3.21 | 1.06 |
| warpAffine | warp_rot_hd | 11.14 | 1.08 | 10.31 |
| remap | remap_lin_hd | 14.32 | 0.98 | 14.61 |
| blobFromImage | blob_hd | 1.06 | 0.30 | 3.53 |
| connectedComponentsWithStats | ccl4_binhd | 20.79 | 2.29 | 9.08 |
| Canny | canny_hdg | 8.30 | 0.81 | 10.25 |
| goodFeaturesToTrack | gftt_hdg | 52.26 | 24.46 | 2.14 |
| line | line_diag_hd | 0.11 | 0.12 | 0.92 **faster** |
| HOGScores | hog_scores_hdg | 51.98 | 329.41 | 0.16 **faster** |
| detectMultiScale | hog_raw_hdg | 627.49 | 74.01 | 8.48 |
| detectMultiScale | hog_group_hdg | 679.33 | 74.81 | 9.08 |
| groupRectangles | group_rects_hdg | 1.04 | 1.48 | 0.70 **faster** |

## Other sizes (270x480 and smaller, point sets, stereo pairs)

| op | row | ours ms | cv2 ms | ours/cv2 |
|---|---|---:|---:|---:|
| Rodrigues | rod_vec | 0.00 | 0.00 | n/a |
| Rodrigues | rod_zero | 0.00 | 0.00 | n/a |
| Rodrigues | rod_mat | 0.01 | 0.00 | n/a |
| Rodrigues | rod_mat_pi | 0.00 | 0.00 | n/a |
| Rodrigues | rod_mat_id | 0.00 | 0.00 | n/a |
| projectPoints | proj_d4 | 0.00 | 0.01 | 0.00 **faster** |
| projectPoints | proj_d5 | 0.00 | 0.01 | 0.00 **faster** |
| projectPoints | proj_d8 | 0.00 | 0.01 | 0.00 **faster** |
| projectPoints | proj_d12 | 0.00 | 0.01 | 0.00 **faster** |
| projectPoints | proj_nodist | 0.00 | 0.01 | 0.00 **faster** |
| fisheye_projectPoints | fproj | 0.00 | 0.01 | 0.00 **faster** |
| undistortPoints | undist_d4 | 0.00 | 0.00 | n/a |
| undistortPoints | undist_d8 | 0.00 | 0.00 | n/a |
| undistortPoints | undist_rp | 0.00 | 0.01 | 0.00 **faster** |
| undistortPoints | undist_zero | 0.00 | 0.00 | n/a |
| fisheye_undistortPoints | fundist | 0.00 | 0.00 | n/a |
| fisheye_undistortPoints | fundist_rp | 0.00 | 0.00 | n/a |
| initUndistortRectifyMap | rectmap_d5 | 1.89 | 0.28 | 6.75 |
| initUndistortRectifyMap | rectmap_id | 0.26 | 0.01 | 26.00 |
| fisheye_initUndistortRectifyMap | frectmap | 0.74 | 1.27 | 0.58 **faster** |
| estimateAffine2D | aff_ransac | 0.01 | 0.03 | 0.33 **faster** |
| estimateAffine2D | aff_tight | 0.02 | 0.03 | 0.67 **faster** |
| solvePnP | pnp_d4 | 0.22 | 0.06 | 3.67 |
| solvePnP | pnp_planar | 0.08 | 0.08 | 1.00 |
| solvePnP | pnp_nodist | 0.29 | 0.09 | 3.22 |
| solvePnPRansac | pnp_ransac | 4.15 | 1.01 | 4.11 |
| findEssentialMat | ess_ransac | 2.48 | 2.23 | 1.11 |
| stereoRectify | rect_zero | 0.01 | 0.02 | 0.50 **faster** |
| stereoRectify | rect_dist | 0.01 | 0.02 | 0.50 **faster** |
| stereoRectify | rect_nozd | 0.01 | 0.02 | 0.50 **faster** |
| findEssentialMat | ess_noisy | 6.20 | 2.67 | 2.32 |
| recoverPose | pose_masked | 0.71 | 0.23 | 3.09 |
| recoverPose | pose_all | 0.96 | 0.21 | 4.57 |
| StereoSGBM | sgbm_dots | 8.31 | 2.25 | 3.69 |
| StereoSGBM | sgbm_block3 | 7.29 | 2.26 | 3.23 |
| StereoSGBM | sgbm_mind | 5.21 | 1.67 | 3.12 |
| findChessboardCorners | chess_a | 8.43 | 0.80 | 10.54 |
| findChessboardCorners | chess_b_rot | 9.08 | 0.88 | 10.32 |
| findChessboardCorners | chess_c | 8.14 | 3.98 | 2.05 |
| findChessboardCorners | chess_none | 9.49 | 11.21 | 0.85 **faster** |
| aruco_detect | aruco_four | 8.27 | 1.10 | 7.52 |
| aruco_detect | aruco_persp | 3.78 | 0.40 | 9.45 |
| aruco_detect | aruco_none | 3.51 | 0.64 | 5.48 |
| fisheye_projectPoints | fproj_zero_rot | 0.00 | 0.01 | 0.00 **faster** |
| fisheye_initUndistortRectifyMap | frectmap_small | 0.23 | 0.02 | 11.50 |
| solvePnPRansac | pnp_ransac_pl | 0.44 | 0.32 | 1.38 |
| flip | flip_y_odd | 0.23 | 0.00 | n/a |
| flip | flip_xy_one | 0.22 | 0.00 | n/a |
| flip | flip_y_f32 | 0.23 | 0.00 | n/a |
| rotate | rotate_180_odd | 0.23 | 0.00 | n/a |
| rotate | rotate_ccw_i16 | 0.23 | 0.00 | n/a |
| transpose | transpose_i32 | 0.22 | 0.00 | n/a |
| absdiff | absdiff_g1 | 0.22 | 0.00 | n/a |
| absdiff | absdiff_i16 | 0.24 | 0.00 | n/a |
| absdiff | absdiff_f32 | 0.22 | 0.00 | n/a |
| bitwise_or | bitwise_or_odd | 0.23 | 0.00 | n/a |
| bitwise_xor | bitwise_xor_f32 | 0.24 | 0.00 | n/a |
| bitwise_not | bitwise_not_one | 0.23 | 0.00 | n/a |
| convert | convert_f32_u8_half | 0.23 | 0.01 | 23.00 |
| convert | convert_f32_i16_scale | 0.23 | 0.01 | 23.00 |
| convert | convert_f64_i32 | 0.22 | 0.01 | 22.00 |
| convert | convert_u8_u8_one | 0.23 | 0.01 | 23.00 |
| bitwise_and | bitwise_and_odd | 0.23 | 0.00 | n/a |
| bitwise_xor | bitwise_xor_i16 | 0.23 | 0.00 | n/a |
| bfmatch | bf_ab | 0.81 | 0.15 | 5.40 |
| bfmatch | bf_one | 0.24 | 0.01 | 24.00 |
| bfmatch | bf_self | 0.62 | 0.13 | 4.77 |
| knnmatch | knn_ab | 0.62 | 0.26 | 2.38 |
| knnmatch | knn_ratio_tight | 0.42 | 0.27 | 1.56 |
| ORB | orb_sm | 10.78 | 2.17 | 4.97 |
| ORB | orb_blank | 6.03 | 0.03 | 201.00 |
| GaussianBlur | gauss7_odd | 0.67 | 0.01 | 67.00 |
| GaussianBlur | gauss_f32 | 0.06 | 0.00 | n/a |
| GaussianBlur | gauss3_one | 0.66 | 0.00 | n/a |
| pyrDown | pyrdown_odd | 0.67 | 0.00 | n/a |
| pyrDown | pyrdown_one | 0.67 | 0.00 | n/a |
| pyrDown | pyrdown_f32 | 0.66 | 0.00 | n/a |
| Sobel | sobel_scharr_g1 | 0.70 | 0.00 | n/a |
| Sobel | sobel_f32_dxx | 0.67 | 0.00 | n/a |
| threshold | thresh_inv_sm | 0.23 | 0.01 | 23.00 |
| threshold | thresh_trunc_g1 | 0.23 | 0.00 | n/a |
| threshold | thresh_tozero_g1 | 0.22 | 0.00 | n/a |
| threshold | thresh_otsu_one | 0.23 | 0.00 | n/a |
| threshold | thresh_f32 | 0.23 | 0.00 | n/a |
| integral | integral_odd | 0.03 | 0.00 | n/a |
| integral | integral_f32 | 0.45 | 0.00 | n/a |
| integral | integral_one | 0.45 | 0.00 | n/a |
| dilate | dilate_cross_sm | 0.54 | 0.07 | 7.71 |
| dilate | dilate_ell_smg | 0.51 | 0.09 | 5.67 |
| erode | erode_ell_odd | 0.03 | 0.00 | n/a |
| dilate | dilate_one | 0.68 | 0.00 | n/a |
| erode | erode_f32 | 0.80 | 0.00 | n/a |
| cvtColor | cvt_rgb2gray_odd | 0.23 | 0.00 | n/a |
| cvtColor | cvt_gray2bgr_g1 | 0.23 | 0.00 | n/a |
| cvtColor | cvt_hsv_odd | 0.02 | 0.00 | n/a |
| cvtColor | cvt_hsv_one | 0.22 | 0.00 | n/a |
| cvtColor | cvt_hsv2bgr_odd | 0.23 | 0.00 | n/a |
| cvtColor | cvt_ycrcb2bgr_sm | 0.31 | 0.04 | 7.75 |
| cvtColor | cvt_gray_f32 | 0.23 | 0.00 | n/a |
| resize | resize_up_lin_sm | 0.90 | 0.17 | 5.29 |
| resize | resize_nn_odd | 0.45 | 0.00 | n/a |
| resize | resize_cub_sm | 0.39 | 0.09 | 4.33 |
| resize | resize_lan_sm | 0.78 | 1.59 | 0.49 **faster** |
| resize | resize_lin_one | 0.03 | 0.00 | n/a |
| resize | resize_lin_f32 | 0.45 | 0.00 | n/a |
| warpAffine | warp_nn_sm | 0.69 | 0.03 | 23.00 |
| warpAffine | warp_cub_smg | 0.79 | 0.09 | 8.78 |
| warpAffine | warp_rep_odd | 0.23 | 0.01 | 23.00 |
| warpAffine | warp_inv_g1 | 0.23 | 0.01 | 23.00 |
| warpAffine | warp_f32 | 0.23 | 0.01 | 23.00 |
| remap | remap_nn_sm | 0.51 | 0.03 | 17.00 |
| remap | remap_cub_smg | 1.48 | 0.10 | 14.80 |
| remap | remap_odd_const | 0.23 | 0.00 | n/a |
| remap | remap_odd_refl | 0.22 | 0.00 | n/a |
| blobFromImage | blob_sm | 0.85 | 0.24 | 3.54 |
| connectedComponentsWithStats | ccl8_bin | 1.34 | 0.32 | 4.19 |
| connectedComponentsWithStats | ccl8_shapes | 0.04 | 0.02 | 2.00 |
| connectedComponentsWithStats | ccl_blank | 0.00 | 0.00 | n/a |
| Canny | canny_smg_l2 | 1.41 | 0.08 | 17.62 |
| Canny | canny_sm5 | 2.30 | 0.16 | 14.37 |
| Canny | canny_blank | 1.78 | 0.01 | 178.00 |
| Canny | canny_g1 | 1.79 | 0.01 | 179.00 |
| findContours | contours_ext_shapes | 0.02 | 0.02 | 1.00 |
| findContours | contours_list_shapes | 0.02 | 0.02 | 1.00 |
| findContours | contours_simple_shapes | 0.02 | 0.02 | 1.00 |
| findContours | contours_ext_bin | 0.46 | 0.06 | 7.67 |
| findContours | contours_list_bin | 0.45 | 0.29 | 1.55 |
| findContours | contours_blank | 0.00 | 0.00 | n/a |
| findContours | contours_full | 0.00 | 0.01 | 0.00 **faster** |
| goodFeaturesToTrack | gftt_smg | 4.69 | 1.89 | 2.48 |
| goodFeaturesToTrack | gftt_blank | 2.76 | 0.01 | 276.00 |
| line | line_steep_g1 | 0.00 | 0.00 | n/a |
| line | line_clip_sm | 0.01 | 0.01 | 1.00 |
| line | line_out_sm | 0.01 | 0.01 | 1.00 |
| line | line_hor_odd | 0.00 | 0.00 | n/a |
| rectangle | rect_edge_sm | 0.01 | 0.01 | 1.00 |
| rectangle | rect_fill_odd | 0.00 | 0.00 | n/a |
| HOGScores | hog_scores_smg | 3.24 | 10.07 | 0.32 **faster** |
| detectMultiScale | hog_raw_smg | 49.88 | 3.93 | 12.69 |
| detectMultiScale | hog_group_smg | 48.91 | 4.07 | 12.02 |
| detectMultiScale | hog_group_smg2 | 50.88 | 3.63 | 14.02 |
| detectMultiScale | hog_none | 51.31 | 4.05 | 12.67 |
| grabCut | grabcut_scene | 35.56 | 9.59 | 3.71 |
| grabCut | grabcut_shot | 55.40 | 14.07 | 3.94 |
| grabCut | grabcut_tiny | 0.10 | 0.07 | 1.43 |
| cornerSubPix | subpix_sm | 1.36 | 0.60 | 2.27 |
| cornerSubPix | subpix_win3 | 0.75 | 0.36 | 2.08 |
| cornerSubPix | subpix_edge | 2.91 | 1.12 | 2.60 |
| calcOpticalFlowPyrLK | lk_sm | 14.66 | 0.32 | 45.81 |
| calcOpticalFlowPyrLK | lk_sm_win9 | 10.58 | 0.14 | 75.57 |
| calcOpticalFlowFarneback | fb_shift | 45.73 | 17.36 | 2.63 |
| calcOpticalFlowFarneback | fb_frames | 47.90 | 22.22 | 2.16 |
| calcOpticalFlowFarneback | fb_poly7 | 36.88 | 18.60 | 1.98 |
| calcOpticalFlowFarneback | fb_tiny | 4.22 | 0.01 | 422.00 |
