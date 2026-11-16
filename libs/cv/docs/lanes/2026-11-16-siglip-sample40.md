# SigLIP labels: 40-picture sample for Mario's review (2026-11-16)

Model `siglip-base-patch16-224` (Apache-2.0) on the mojo-faces CPU runner; labels from `data/siglip/categories.tsv` (18) and `data/siglip/tags.tsv` (142, approved).
40 pictures drawn with a fixed seed from the library pictures embedded so far (any category). Category numbers are cosines (the category is the
largest one); tag numbers are SigLIP's sigmoid probability (learned scale 117.3, bias -12.93). `lib` is the category in the sidecar today, `eye` is
my own label from looking at the picture (alternatives with `|`). Nothing is written to sidecars: predictions live only in `<image>.labels.json`
and the `label` table until you approve moving tags.

Check on these 40 against `eye`: SigLIP top-1 32 of 40 (0.80), top-3 38 of 40 (0.95); the library category 16 of 40 (0.40).
On 1405 pictures against the library category alone top-1 is 0.276, which mostly measures the library labels (game props filed under icons-ui, props against furniture).

| # | picture | lib | eye | SigLIP categories (cosine) | SigLIP tags (p) |
|---|---|---|---|---|---|
| 1 | `images/tech-devices/lab-robot-petri-cine-photo-10024_00002_-000a0e6b.jpg` | tech-devices | science-medical | science-medical 0.061, tech-devices 0.020, furniture 0.014 | laboratory 0.147, microscope 0.102, robot 0.091, science 0.006, lamp 0.002 |
| 2 | `images/health-wellness/ceai-extract-medicament-artemisia_00002_-0014a21c.png` | health-wellness | health-wellness | health-wellness 0.073, food 0.007, furniture -0.001 | tea 0.008, herbs 0.008, bottle 0.005, table 0.000, health 0.000 |
| 3 | `images/tech-devices/lab-robot-tubes-cine-photo-10021_00001_-0028f9ed.jpg` | tech-devices | science-medical|tech-devices | furniture 0.027, tech-devices 0.027, science-medical 0.026 | robot 0.235, laboratory 0.121, microscope 0.013, technology 0.004, science 0.001 |
| 4 | `images/weapons/tool_crowbar-view1-cut-0032763a.png` | weapons | props | props 0.028, furniture 0.012, weapons 0.009 | black background 0.035, tool 0.011, knife 0.000, sword 0.000, silhouette 0.000 |
| 5 | `images/abstract/cut-plexus-navy-bell_00001_-0035e019.png` | abstract | icons-ui | icons-ui 0.054, tech-devices 0.031, props 0.022 | black background 0.064, flat icon 0.005, security 0.005, glowing 0.003, button 0.003 |
| 6 | `images/props/sj_trash_bag_pile_b-003f22e0.png` | props | props | props 0.040, clothing 0.004, tech-devices -0.005 | gray 0.000, white background 0.000, black background 0.000, black 0.000, studio shot 0.000 |
| 7 | `images/nature/ic-botanical-tech-search_00001_-0042d447.png` | nature | icons-ui | props 0.072, icons-ui 0.046, tech-devices 0.030 | green 0.015, illustration 0.004, flat icon 0.003, white background 0.003, minimalist 0.002 |
| 8 | `images/science-medical/eg088-organs-inflamed-peritoneum-ar-00523929.jpg` | science-medical | science-medical | science-medical 0.003, characters -0.005, props -0.005 | medical 0.007, health 0.001, science 0.000, energy 0.000, black background 0.000 |
| 9 | `images/nature/ic-botanical-tech-bell_00001_-0060fad7.png` | nature | icons-ui | icons-ui 0.036, props 0.035, characters 0.024 | green 0.010, illustration 0.002, flat icon 0.001, button 0.001, leaf 0.001 |
| 10 | `images/tech-devices/z_image_turbo_bf16_00004_-00ac4a92.png` | tech-devices | animals | animals 0.078, clothing 0.015, weapons 0.013 | snow 0.004, brown 0.001, blurred background 0.000, dog 0.000, macro 0.000 |
| 11 | `images/furniture/shelf_03_col-00bc08e9.png` | furniture | surfaces | architecture 0.064, furniture 0.059, surfaces 0.054 | 3d render 0.005, pattern 0.003, table 0.001, white 0.001, house 0.001 |
| 12 | `images/food/db042-freshly-baked-sourdo-00d179c5.jpg` | food | food | food 0.053, furniture 0.000, props -0.012 | bread 0.067, dessert 0.002, table 0.000, meat 0.000, coffee 0.000 |
| 13 | `images/icons-ui/sneakers_00004_-011aac2f.png` | icons-ui | clothing | props 0.034, clothing 0.019, surfaces -0.004 | shoes 0.020, 3d render 0.000, studio shot 0.000, black background 0.000, game asset 0.000 |
| 14 | `images/health-wellness/nat-child-smile-turn-44-0124e7be.jpg` | health-wellness | people | people 0.041, clothing 0.026, animals 0.021 | child 0.364, person 0.063, man 0.005, studio shot 0.003, blurred background 0.001 |
| 15 | `images/clothing/db004-farmer-s-boots-walki-014372ee.jpg` | clothing | nature | clothing 0.020, people 0.017, animals 0.010 | blurred background 0.001, shoes 0.001, man 0.000, person 0.000, macro 0.000 |
| 16 | `images/icons-ui/cardboard_00001_-015b5ec2.png` | icons-ui | props | props 0.068, surfaces 0.051, furniture 0.039 | isometric 0.004, brown 0.002, wood texture 0.001, 3d render 0.001, minimalist 0.000 |
| 17 | `images/science-medical/db104-tapeworm-scolex-head-0170577c.jpg` | science-medical | science-medical | science-medical 0.046, animals 0.045, characters 0.023 | cells 0.006, insect 0.002, dna 0.002, medical 0.001, brown 0.001 |
| 18 | `images/science-medical/44-amoeba-fluorescence_00001_-08b54e1a.png` | science-medical | science-medical | science-medical 0.058, animals 0.013, characters 0.007 | cells 0.249, glowing 0.022, black background 0.012, science 0.008, dna 0.004 |
| 19 | `images/people/dusmani-naturali-in-loc-de-insecticide_00001_-0c87360a.png` | people | nature | nature 0.021, animals 0.009, food 0.008 | grass 0.022, herbs 0.009, vegetables 0.009, flower 0.001, fruit 0.000 |
| 20 | `images/tech-devices/db094-giardia-lamblia-trop-57a7a9dd.png` | tech-devices | science-medical | science-medical 0.063, animals 0.030, abstract 0.010 | cells 0.355, macro 0.025, microscope 0.007, science 0.004, face 0.004 |
| 21 | `images/characters/t_hair_1_normal_png-57fd0ad8.png` | characters | surfaces | abstract 0.069, surfaces 0.036, science-medical 0.019 | purple 0.028, pattern 0.004, 3d render 0.004, blue 0.001, glowing 0.001 |
| 22 | `images/people/organic-in-sarcina-cohorta-norvegiana-moba_00001_-58a7e70d.png` | people | food | food 0.075, furniture 0.055, interiors 0.041 | table 0.175, vegetables 0.088, kitchen 0.010, fruit 0.005, health 0.004 |
| 23 | `images/tech-devices/pm1-58e2b932.jpg` | tech-devices | science-medical|tech-devices | tech-devices 0.029, science-medical 0.019, characters 0.016 | robot 0.686, technology 0.014, laboratory 0.008, medical 0.002, science 0.002 |
| 24 | `images/weapons/old_180-58fd4e4b.png` | weapons | props | props 0.077, characters 0.021, weapons 0.016 | tool 0.008, 3d render 0.002, studio shot 0.000, white background 0.000, black background 0.000 |
| 25 | `images/tech-devices/a0_spec-7704_00001_-59468f39.jpg` | tech-devices | tech-devices | tech-devices 0.023, characters 0.007, animals 0.003 | robot 0.447, technology 0.002, 3d render 0.001, security 0.000, armor 0.000 |
| 26 | `images/tech-devices/z_image_turbo_bf16_00015_-5afc840f.png` | tech-devices | animals | animals 0.082, clothing 0.016, weapons 0.014 | snow 0.002, brown 0.000, blurred background 0.000, dog 0.000, bird 0.000 |
| 27 | `images/health-wellness/ne24-fresh-herbs-parsley-5c738d95.png` | health-wellness | health-wellness|nature | health-wellness 0.068, food 0.041, furniture 0.018 | herbs 0.688, vegetables 0.066, plant 0.005, green 0.001, bottle 0.001 |
| 28 | `images/nature/vace_shot2_00029_-5f010430.png` | nature | characters | characters 0.022, props 0.012, weapons 0.006 | night 0.136, 3d render 0.019, glowing 0.008, cinematic 0.003, black 0.001 |
| 29 | `images/surfaces/sj_road_barrier_00001_-60b7c0a1.png` | surfaces | props | props 0.045, architecture 0.026, furniture 0.025 | white background 0.001, red 0.000, bridge 0.000, security 0.000, tool 0.000 |
| 30 | `images/surfaces/tool_drill-img-60d45a44.png` | surfaces | tech-devices | tech-devices 0.011, weapons 0.003, props -0.000 | tool 0.001, studio shot 0.000, black background 0.000, gun 0.000, white background 0.000 |
| 31 | `images/science-medical/db103-tapeworm-scolex-head-61823983.jpg` | science-medical | science-medical | props 0.047, animals 0.035, characters 0.026 | fish 0.085, knife 0.030, tool 0.024, glowing 0.005, microscope 0.005 |
| 32 | `images/architecture/tavern_00001_-61c64721.png` | architecture | architecture | architecture 0.064, interiors 0.040, furniture 0.018 | house 0.017, street 0.004, vintage 0.002, white 0.000, brown 0.000 |
| 33 | `images/furniture/chair_01_v0-6495334b.png` | furniture | furniture | furniture 0.072, props 0.057, surfaces 0.023 | chair 0.160, 3d render 0.003, table 0.000, studio shot 0.000, sofa 0.000 |
| 34 | `images/animals/street_dog-cut-64bcd393.png` | animals | animals|characters|props | animals 0.045, props 0.024, characters 0.019 | 3d render 0.002, dog 0.001, studio shot 0.000, black background 0.000, brown 0.000 |
| 35 | `images/health-wellness/nd44-a-child-sitting-on-t-ae27252e.jpg` | health-wellness | people | animals 0.053, people 0.023, tech-devices -0.001 | child 0.005, dog 0.004, grass 0.000, person 0.000, health 0.000 |
| 36 | `images/nature/tex-ae4c8d03.png` | nature | surfaces | surfaces 0.045, health-wellness 0.025, furniture 0.010 | leaf 0.004, tree 0.002, herbs 0.002, wood texture 0.001, green 0.001 |
| 37 | `images/health-wellness/nat2-ferment-veg-jars-39-aea0e19a.jpg` | health-wellness | food | food 0.037, health-wellness 0.033, furniture -0.011 | herbs 0.023, vegetables 0.009, bottle 0.001, table 0.000, meat 0.000 |
| 38 | `images/furniture/shelf_02_v0-b7468f3c.png` | furniture | furniture | furniture 0.054, props 0.049, surfaces 0.009 | 3d render 0.000, brown 0.000, table 0.000, chair 0.000, studio shot 0.000 |
| 39 | `images/architecture/newspaper_box_05_v0-b78a5352.png` | architecture | furniture|props | props 0.073, furniture 0.064, tech-devices 0.058 | 3d render 0.029, computer 0.002, brown 0.001, studio shot 0.001, game asset 0.001 |
| 40 | `images/tech-devices/lab-robot-tub-10023-01-bb19e992.jpg` | tech-devices | science-medical|tech-devices | science-medical 0.035, furniture 0.026, tech-devices 0.021 | robot 0.181, laboratory 0.125, microscope 0.018, technology 0.003, science 0.003 |
