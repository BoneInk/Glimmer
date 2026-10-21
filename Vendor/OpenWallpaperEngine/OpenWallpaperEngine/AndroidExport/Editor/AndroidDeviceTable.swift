extension AndroidDevice {
    /// Popular Android devices and their native screens, portrait; each `source` is the spec page the resolution comes from.
    static let table: [AndroidDevice] = [
        // Samsung Galaxy S
        .phone("Samsung", "Galaxy S26 Ultra", 1440, 3120, 2026, source: "https://www.gsmarena.com/samsung_galaxy_s26_ultra_5g-14320.php"),
        .phone("Samsung", "Galaxy S26+", 1440, 3120, 2026, source: "https://www.gsmarena.com/samsung_galaxy_s26+_5g-14457.php"),
        .phone("Samsung", "Galaxy S26", 1080, 2340, 2026, source: "https://www.gsmarena.com/samsung_galaxy_s26_5g-14456.php"),
        .phone("Samsung", "Galaxy S26 FE", 1080, 2340, 2026, source: "https://www.gsmarena.com/samsung_galaxy_s26_fe_5g-14870.php"),
        .phone("Samsung", "Galaxy S25 Ultra", 1440, 3120, 2025, source: "https://www.gsmarena.com/samsung_galaxy_s25_ultra-13322.php"),
        .phone("Samsung", "Galaxy S25+", 1440, 3120, 2025, source: "https://www.gsmarena.com/samsung_galaxy_s25+-13609.php"),
        .phone("Samsung", "Galaxy S25", 1080, 2340, 2025, source: "https://www.gsmarena.com/samsung_galaxy_s25-13610.php"),
        .phone("Samsung", "Galaxy S25 Edge", 1440, 3120, 2025, source: "https://www.gsmarena.com/samsung_galaxy_s25_edge-13506.php"),
        .phone("Samsung", "Galaxy S25 FE", 1080, 2340, 2025, source: "https://www.gsmarena.com/samsung_galaxy_s25_fe_5g-14042.php"),
        .phone("Samsung", "Galaxy S24 Ultra", 1440, 3120, 2024, source: "https://www.gsmarena.com/samsung_galaxy_s24_ultra-12771.php"),
        .phone("Samsung", "Galaxy S24+", 1440, 3120, 2024, source: "https://www.gsmarena.com/samsung_galaxy_s24+-12772.php"),
        .phone("Samsung", "Galaxy S24", 1080, 2340, 2024, source: "https://www.gsmarena.com/samsung_galaxy_s24-12773.php"),
        .phone("Samsung", "Galaxy S24 FE", 1080, 2340, 2024, source: "https://www.gsmarena.com/samsung_galaxy_s24_fe-13262.php"),
        .phone("Samsung", "Galaxy S23 Ultra", 1440, 3088, 2023, source: "https://www.gsmarena.com/samsung_galaxy_s23_ultra-12024.php"),
        .phone("Samsung", "Galaxy S23+", 1080, 2340, 2023, source: "https://www.gsmarena.com/samsung_galaxy_s23+-12083.php"),
        .phone("Samsung", "Galaxy S23", 1080, 2340, 2023, source: "https://www.gsmarena.com/samsung_galaxy_s23-12082.php"),
        .phone("Samsung", "Galaxy S23 FE", 1080, 2340, 2023, source: "https://www.gsmarena.com/samsung_galaxy_s23_fe-12520.php"),
        .phone("Samsung", "Galaxy S22 Ultra", 1440, 3088, 2022, source: "https://www.gsmarena.com/samsung_galaxy_s22_ultra_5g-11251.php"),
        .phone("Samsung", "Galaxy S22+", 1080, 2340, 2022, source: "https://www.gsmarena.com/samsung_galaxy_s22+_5g-11252.php"),
        .phone("Samsung", "Galaxy S22", 1080, 2340, 2022, source: "https://www.gsmarena.com/samsung_galaxy_s22_5g-11253.php"),

        // Samsung Galaxy A
        .phone("Samsung", "Galaxy A57", 1080, 2340, 2026, source: "https://www.gsmarena.com/samsung_galaxy_a57_5g-14379.php"),
        .phone("Samsung", "Galaxy A56", 1080, 2340, 2025, source: "https://www.gsmarena.com/samsung_galaxy_a56-13603.php"),
        .phone("Samsung", "Galaxy A36", 1080, 2340, 2025, source: "https://www.gsmarena.com/samsung_galaxy_a36-13497.php"),
        .phone("Samsung", "Galaxy A16 5G", 1080, 2340, 2024, source: "https://www.gsmarena.com/samsung_galaxy_a16_5g-13346.php"),
        .phone("Samsung", "Galaxy A55", 1080, 2340, 2024, source: "https://www.gsmarena.com/samsung_galaxy_a55-12824.php"),
        .phone("Samsung", "Galaxy A35", 1080, 2340, 2024, source: "https://www.gsmarena.com/samsung_galaxy_a35-12705.php"),

        // Samsung Galaxy Z Fold
        .foldable("Samsung", "Galaxy Z Fold8 Ultra", .main, 2256, 2504, 2026, source: "https://www.gsmarena.com/samsung_galaxy_z_fold8_ultra_5g-14802.php"),
        .foldable("Samsung", "Galaxy Z Fold8 Ultra", .cover, 1080, 2520, 2026, source: "https://www.gsmarena.com/samsung_galaxy_z_fold8_ultra_5g-14802.php"),
        .foldable("Samsung", "Galaxy Z Fold8", .main, 1848, 2448, 2026, source: "https://www.gsmarena.com/samsung_galaxy_z_fold_wide_5g-14673.php"),
        .foldable("Samsung", "Galaxy Z Fold8", .cover, 1248, 1972, 2026, source: "https://www.gsmarena.com/samsung_galaxy_z_fold_wide_5g-14673.php"),
        .foldable("Samsung", "Galaxy Z Fold7", .main, 1968, 2184, 2025, source: "https://www.gsmarena.com/samsung_galaxy_z_fold7-13826.php"),
        .foldable("Samsung", "Galaxy Z Fold7", .cover, 1080, 2520, 2025, source: "https://www.gsmarena.com/samsung_galaxy_z_fold7-13826.php"),
        .foldable("Samsung", "Galaxy Z Fold6", .main, 1856, 2160, 2024, source: "https://www.gsmarena.com/samsung_galaxy_z_fold6-13147.php"),
        .foldable("Samsung", "Galaxy Z Fold6", .cover, 968, 2376, 2024, source: "https://www.gsmarena.com/samsung_galaxy_z_fold6-13147.php"),
        .foldable("Samsung", "Galaxy Z Fold5", .main, 1812, 2176, 2023, source: "https://www.gsmarena.com/samsung_galaxy_z_fold5-12418.php"),
        .foldable("Samsung", "Galaxy Z Fold5", .cover, 904, 2316, 2023, source: "https://www.gsmarena.com/samsung_galaxy_z_fold5-12418.php"),
        .foldable("Samsung", "Galaxy Z Fold4", .main, 1812, 2176, 2022, source: "https://www.gsmarena.com/samsung_galaxy_z_fold4-11737.php"),
        .foldable("Samsung", "Galaxy Z Fold4", .cover, 904, 2316, 2022, source: "https://www.gsmarena.com/samsung_galaxy_z_fold4-11737.php"),

        // Samsung Galaxy Z Flip
        .foldable("Samsung", "Galaxy Z Flip8", .main, 1080, 2520, 2026, source: "https://www.gsmarena.com/samsung_galaxy_z_flip8_5g-14803.php"),
        .foldable("Samsung", "Galaxy Z Flip8", .cover, 948, 1048, 2026, source: "https://www.gsmarena.com/samsung_galaxy_z_flip8_5g-14803.php"),
        .foldable("Samsung", "Galaxy Z Flip7", .main, 1080, 2520, 2025, source: "https://www.gsmarena.com/samsung_galaxy_z_flip7-13712.php"),
        .foldable("Samsung", "Galaxy Z Flip7", .cover, 948, 1048, 2025, source: "https://www.gsmarena.com/samsung_galaxy_z_flip7-13712.php"),
        .foldable("Samsung", "Galaxy Z Flip7 FE", .main, 1080, 2640, 2025, source: "https://www.gsmarena.com/samsung_galaxy_z_flip7_fe_5g-13844.php"),
        .foldable("Samsung", "Galaxy Z Flip7 FE", .cover, 720, 748, 2025, source: "https://www.gsmarena.com/samsung_galaxy_z_flip7_fe_5g-13844.php"),
        .foldable("Samsung", "Galaxy Z Flip6", .main, 1080, 2640, 2024, source: "https://www.gsmarena.com/samsung_galaxy_z_flip6-13192.php"),
        .foldable("Samsung", "Galaxy Z Flip6", .cover, 720, 748, 2024, source: "https://www.gsmarena.com/samsung_galaxy_z_flip6-13192.php"),
        .foldable("Samsung", "Galaxy Z Flip5", .main, 1080, 2640, 2023, source: "https://www.gsmarena.com/samsung_galaxy_z_flip5-12252.php"),
        .foldable("Samsung", "Galaxy Z Flip5", .cover, 720, 748, 2023, source: "https://www.gsmarena.com/samsung_galaxy_z_flip5-12252.php"),
        .foldable("Samsung", "Galaxy Z Flip4", .main, 1080, 2640, 2022, source: "https://www.gsmarena.com/samsung_galaxy_z_flip4-11538.php"),
        .foldable("Samsung", "Galaxy Z Flip4", .cover, 260, 512, 2022, source: "https://www.gsmarena.com/samsung_galaxy_z_flip4-11538.php"),

        // Samsung Galaxy Tab S
        .tablet("Samsung", "Galaxy Tab S12 Ultra", 1848, 2960, 2026, source: "https://www.gsmarena.com/samsung_galaxy_tab_s12_ultra_5g-14811.php"),
        .tablet("Samsung", "Galaxy Tab S11 Ultra", 1848, 2960, 2025, source: "https://www.gsmarena.com/samsung_galaxy_tab_s11_ultra_5g-14057.php"),
        .tablet("Samsung", "Galaxy Tab S11", 1600, 2560, 2025, source: "https://www.gsmarena.com/samsung_galaxy_tab_s11_5g-14058.php"),
        .tablet("Samsung", "Galaxy Tab S10 FE+", 1800, 2880, 2025, source: "https://www.gsmarena.com/samsung_galaxy_tab_s10_fe+-13760.php"),
        .tablet("Samsung", "Galaxy Tab S10 FE", 1440, 2304, 2025, source: "https://www.gsmarena.com/samsung_galaxy_tab_s10_fe-13761.php"),
        .tablet("Samsung", "Galaxy Tab S10 Ultra", 1848, 2960, 2024, source: "https://www.gsmarena.com/samsung_galaxy_tab_s10_ultra-13362.php"),
        .tablet("Samsung", "Galaxy Tab S10+", 1752, 2800, 2024, source: "https://www.gsmarena.com/samsung_galaxy_tab_s10+-13363.php"),
        .tablet("Samsung", "Galaxy Tab S9 FE+", 1600, 2560, 2023, source: "https://www.gsmarena.com/samsung_galaxy_tab_s9_fe+-12609.php"),
        .tablet("Samsung", "Galaxy Tab S9 FE", 1440, 2304, 2023, source: "https://www.gsmarena.com/samsung_galaxy_tab_s9_fe-12517.php"),
        .tablet("Samsung", "Galaxy Tab S9 Ultra", 1848, 2960, 2023, source: "https://www.gsmarena.com/samsung_galaxy_tab_s9_ultra-12217.php"),
        .tablet("Samsung", "Galaxy Tab S9+", 1752, 2800, 2023, source: "https://www.gsmarena.com/samsung_galaxy_tab_s9+-12440.php"),
        .tablet("Samsung", "Galaxy Tab S9", 1600, 2560, 2023, source: "https://www.gsmarena.com/samsung_galaxy_tab_s9-12439.php"),
        .tablet("Samsung", "Galaxy Tab S8 Ultra", 1848, 2960, 2022, source: "https://www.gsmarena.com/samsung_galaxy_tab_s8_ultra-11274.php"),
        .tablet("Samsung", "Galaxy Tab S8+", 1752, 2800, 2022, source: "https://www.gsmarena.com/samsung_galaxy_tab_s8+-11342.php"),
        .tablet("Samsung", "Galaxy Tab S8", 1600, 2560, 2022, source: "https://www.gsmarena.com/samsung_galaxy_tab_s8-11343.php"),

        // Google Pixel
        .phone("Google", "Pixel 11 Pro XL", 1344, 2992, 2026, source: "https://www.gsmarena.com/google_pixel_11_pro_xl_5g-14800.php"),
        .phone("Google", "Pixel 11 Pro", 1280, 2856, 2026, source: "https://www.gsmarena.com/google_pixel_11_pro_5g-14801.php"),
        .phone("Google", "Pixel 11", 1080, 2424, 2026, source: "https://www.gsmarena.com/google_pixel_11_5g-14799.php"),
        .phone("Google", "Pixel 10a", 1080, 2424, 2026, source: "https://www.gsmarena.com/google_pixel_10a_5g-14474.php"),
        .phone("Google", "Pixel 10 Pro XL", 1344, 2992, 2025, source: "https://www.gsmarena.com/google_pixel_10_pro_xl_5g-13988.php"),
        .phone("Google", "Pixel 10 Pro", 1280, 2856, 2025, source: "https://www.gsmarena.com/google_pixel_10_pro_5g-13987.php"),
        .phone("Google", "Pixel 10", 1080, 2424, 2025, source: "https://www.gsmarena.com/google_pixel_10_5g-13979.php"),
        .phone("Google", "Pixel 9a", 1080, 2424, 2025, source: "https://www.gsmarena.com/google_pixel_9a-13478.php"),
        .phone("Google", "Pixel 9 Pro XL", 1344, 2992, 2024, source: "https://www.gsmarena.com/google_pixel_9_pro_xl-13217.php"),
        .phone("Google", "Pixel 9 Pro", 1280, 2856, 2024, source: "https://www.gsmarena.com/google_pixel_9_pro-13218.php"),
        .phone("Google", "Pixel 9", 1080, 2424, 2024, source: "https://www.gsmarena.com/google_pixel_9-13219.php"),
        .phone("Google", "Pixel 8a", 1080, 2400, 2024, source: "https://www.gsmarena.com/google_pixel_8a-12937.php"),
        .phone("Google", "Pixel 8 Pro", 1344, 2992, 2023, source: "https://www.gsmarena.com/google_pixel_8_pro-12545.php"),
        .phone("Google", "Pixel 8", 1080, 2400, 2023, source: "https://www.gsmarena.com/google_pixel_8-12546.php"),
        .phone("Google", "Pixel 7a", 1080, 2400, 2023, source: "https://www.gsmarena.com/google_pixel_7a-12170.php"),
        .phone("Google", "Pixel 7 Pro", 1440, 3120, 2022, source: "https://www.gsmarena.com/google_pixel_7_pro-11908.php"),
        .phone("Google", "Pixel 7", 1080, 2400, 2022, source: "https://www.gsmarena.com/google_pixel_7-11903.php"),

        // Google Pixel Fold
        .foldable("Google", "Pixel 11 Pro Fold", .main, 2076, 2152, 2026, source: "https://www.gsmarena.com/google_pixel_11_pro_fold-14874.php"),
        .foldable("Google", "Pixel 11 Pro Fold", .cover, 1080, 2342, 2026, source: "https://www.gsmarena.com/google_pixel_11_pro_fold-14874.php"),
        .foldable("Google", "Pixel 10 Pro Fold", .main, 2076, 2152, 2025, source: "https://www.gsmarena.com/google_pixel_10_pro_fold-14014.php"),
        .foldable("Google", "Pixel 10 Pro Fold", .cover, 1080, 2364, 2025, source: "https://www.gsmarena.com/google_pixel_10_pro_fold-14014.php"),
        .foldable("Google", "Pixel 9 Pro Fold", .main, 2076, 2152, 2024, source: "https://www.gsmarena.com/google_pixel_9_pro_fold-13220.php"),
        .foldable("Google", "Pixel 9 Pro Fold", .cover, 1080, 2424, 2024, source: "https://www.gsmarena.com/google_pixel_9_pro_fold-13220.php"),
        .foldable("Google", "Pixel Fold", .main, 1840, 2208, 2023, source: "https://www.gsmarena.com/google_pixel_fold-12265.php"),
        .foldable("Google", "Pixel Fold", .cover, 1080, 2092, 2023, source: "https://www.gsmarena.com/google_pixel_fold-12265.php"),

        // Google Pixel Tablet
        .tablet("Google", "Pixel Tablet", 1600, 2560, 2023, source: "https://www.gsmarena.com/google_pixel_tablet-11905.php"),

        // OnePlus
        .phone("OnePlus", "15", 1272, 2772, 2025, source: "https://www.gsmarena.com/oneplus_15_5g-14206.php"),
        .phone("OnePlus", "13R", 1264, 2780, 2025, source: "https://www.gsmarena.com/oneplus_13r-13548.php"),
        .phone("OnePlus", "13", 1440, 3168, 2024, source: "https://www.gsmarena.com/oneplus_13-13477.php"),
        .phone("OnePlus", "Nord 4", 1240, 2772, 2024, source: "https://www.gsmarena.com/oneplus_nord_4-13200.php"),
        .phone("OnePlus", "12", 1440, 3168, 2023, source: "https://www.gsmarena.com/oneplus_12-12725.php"),
        .phone("OnePlus", "11", 1440, 3216, 2023, source: "https://www.gsmarena.com/oneplus_11-11893.php"),

        // OnePlus Pad
        .tablet("OnePlus", "Pad 3", 2400, 3392, 2025, source: "https://www.gsmarena.com/oneplus_pad_3_(global)-13881.php"),
        .tablet("OnePlus", "Pad 2", 2120, 3000, 2024, source: "https://www.gsmarena.com/oneplus_pad_2-13210.php"),
        .tablet("OnePlus", "Pad", 2000, 2800, 2023, source: "https://www.gsmarena.com/oneplus_pad-12112.php"),

        // Xiaomi
        .phone("Xiaomi", "15 Ultra", 1440, 3200, 2025, source: "https://www.gsmarena.com/xiaomi_15_ultra-13657.php"),
        .phone("Xiaomi", "15", 1200, 2670, 2024, source: "https://www.gsmarena.com/xiaomi_15-13472.php"),
        .phone("Xiaomi", "14 Ultra", 1440, 3200, 2024, source: "https://www.gsmarena.com/xiaomi_14_ultra-12827.php"),
        .phone("Xiaomi", "14", 1200, 2670, 2023, source: "https://www.gsmarena.com/xiaomi_14-12626.php"),
        .phone("Xiaomi", "13", 1080, 2400, 2022, source: "https://www.gsmarena.com/xiaomi_13-12013.php"),

        // Xiaomi Redmi Note
        .phone("Xiaomi", "Redmi Note 14 Pro 5G", 1220, 2712, 2025, source: "https://www.gsmarena.com/xiaomi_redmi_note_14_pro_5g_(global)-13613.php"),
        .phone("Xiaomi", "Redmi Note 13 Pro", 1220, 2712, 2023, source: "https://www.gsmarena.com/xiaomi_redmi_note_13_pro-12581.php"),

        // Xiaomi POCO
        .phone("Xiaomi", "POCO F7 Pro", 1440, 3200, 2025, source: "https://www.gsmarena.com/xiaomi_poco_f7_pro-13724.php"),
        .phone("Xiaomi", "POCO F6", 1220, 2712, 2024, source: "https://www.gsmarena.com/xiaomi_poco_f6-13000.php"),

        // Xiaomi Pad
        .tablet("Xiaomi", "Pad 7", 2136, 3200, 2024, source: "https://www.gsmarena.com/xiaomi_pad_7-13475.php"),
        .tablet("Xiaomi", "Pad 6", 1800, 2880, 2023, source: "https://www.gsmarena.com/xiaomi_pad_6-12237.php"),

        // Motorola Edge
        .phone("Motorola", "Edge 50", 1220, 2712, 2024, source: "https://www.gsmarena.com/motorola_edge_50-13231.php"),
        .phone("Motorola", "Edge (2024)", 1080, 2400, 2024, source: "https://www.gsmarena.com/motorola_edge_(2024)-13111.php"),

        // Motorola Razr
        .foldable("Motorola", "Razr 50", .main, 1080, 2640, 2024, source: "https://www.gsmarena.com/motorola_razr_50-13151.php"),
        .foldable("Motorola", "Razr 50", .cover, 1056, 1066, 2024, source: "https://www.gsmarena.com/motorola_razr_50-13151.php"),
        .foldable("Motorola", "Razr 2024", .main, 1080, 2640, 2024, source: "https://www.gsmarena.com/motorola_razr_2024-13214.php"),
        .foldable("Motorola", "Razr 2024", .cover, 1056, 1066, 2024, source: "https://www.gsmarena.com/motorola_razr_2024-13214.php"),

        // Motorola Moto G
        .phone("Motorola", "Moto G85", 1080, 2400, 2024, source: "https://www.gsmarena.com/motorola_moto_g85-13144.php"),

        // Nothing Phone
        .phone("Nothing", "Phone (3)", 1260, 2800, 2025, source: "https://www.gsmarena.com/nothing_phone_(3)_5g-13969.php"),
        .phone("Nothing", "Phone (3a)", 1080, 2392, 2025, source: "https://www.gsmarena.com/nothing_phone_(3a)-13672.php"),
        .phone("Nothing", "Phone (2a)", 1080, 2412, 2024, source: "https://www.gsmarena.com/nothing_phone_(2a)-12760.php"),
        .phone("Nothing", "Phone (2)", 1080, 2412, 2023, source: "https://www.gsmarena.com/nothing_phone_(2)-12386.php"),

        // Sony Xperia
        .phone("Sony", "Xperia 1 VII", 1080, 2340, 2025, source: "https://www.gsmarena.com/sony_xperia_1_vii_5g-13843.php"),
        .phone("Sony", "Xperia 1 VI", 1080, 2340, 2024, source: "https://www.gsmarena.com/sony_xperia_1_vi-13003.php"),
        .phone("Sony", "Xperia 10 VI", 1080, 2520, 2024, source: "https://www.gsmarena.com/sony_xperia_10_vi-13002.php"),

        // OPPO Find X
        .phone("OPPO", "Find X8 Pro", 1264, 2780, 2024, source: "https://www.gsmarena.com/oppo_find_x8_pro-13467.php"),
        .phone("OPPO", "Find X7 Ultra", 1440, 3168, 2024, source: "https://www.gsmarena.com/oppo_find_x7_ultra-12752.php"),

        // OPPO Find N
        .foldable("OPPO", "Find N5", .main, 2248, 2480, 2025, source: "https://www.gsmarena.com/oppo_find_n5-13659.php"),
        .foldable("OPPO", "Find N5", .cover, 1140, 2616, 2025, source: "https://www.gsmarena.com/oppo_find_n5-13659.php"),
        .foldable("OPPO", "Find N3", .main, 2268, 2440, 2023, source: "https://www.gsmarena.com/oppo_find_n3-12205.php"),
        .foldable("OPPO", "Find N3", .cover, 1116, 2484, 2023, source: "https://www.gsmarena.com/oppo_find_n3-12205.php"),

        // vivo X
        .phone("vivo", "X200 Pro", 1260, 2800, 2024, source: "https://www.gsmarena.com/vivo_x200_pro-13410.php"),
        .phone("vivo", "X100 Pro", 1260, 2800, 2023, source: "https://www.gsmarena.com/vivo_x100_pro-12694.php"),

        // vivo X Fold
        .foldable("vivo", "X Fold3", .main, 2200, 2480, 2024, source: "https://www.gsmarena.com/vivo_x_fold3-12900.php"),
        .foldable("vivo", "X Fold3", .cover, 1172, 2748, 2024, source: "https://www.gsmarena.com/vivo_x_fold3-12900.php"),
    ]
}
