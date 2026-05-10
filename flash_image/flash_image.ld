/* Wrap raw flash_image.bin into a loadable ELF with a single LOAD
 * segment at 0x88200000. FESVR's --payload= reads PT_LOAD segments and
 * writes them to the simulated DRAM via TSI before MSIP wakes hart 0. */

ENTRY(_flash_image_start)

SECTIONS
{
    . = 0x88200000;
    .flash : {
        _flash_image_start = .;
        *(.data)
        _flash_image_end = .;
    }
}
