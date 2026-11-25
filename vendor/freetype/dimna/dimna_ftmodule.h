/*
 * The FreeType modules compiled into dimna on macOS (build.zig, addMacGui), in place of
 * include/freetype/config/ftmodule.h: outline fonts as macOS installs them (TrueType,
 * OpenType with TrueType or CFF outlines, collections), the autohinter and the two
 * rasterizers. Left out, with their sources: Type 1, CID, PFR, Type 42, Windows FNT, PCF,
 * BDF, the signed-distance-field renderers and OT-SVG.
 */

FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
FT_USE_MODULE( FT_Renderer_Class, ft_raster1_renderer_class )

/* EOF */
