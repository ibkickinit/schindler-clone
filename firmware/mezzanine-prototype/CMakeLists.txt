cmake_minimum_required(VERSION 3.13)

# Pull in Pico SDK (must be before project())
set(PICO_BOARD pico CACHE STRING "Board type")
include(pico_sdk_import.cmake)

project(schindler_mezzanine_prototype C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(mezzanine_prototype
    main.c
)

# Generate PIO header from .pio source
pico_generate_pio_header(mezzanine_prototype
    ${CMAKE_CURRENT_LIST_DIR}/ws2812.pio
)

# Link Pico SDK libraries
target_link_libraries(mezzanine_prototype
    pico_stdlib
    hardware_i2c
    hardware_pio
    hardware_timer
    hardware_clocks
)

# stdio routing: USB-CDC on, UART off (no UART pins wired)
pico_enable_stdio_usb(mezzanine_prototype 1)
pico_enable_stdio_uart(mezzanine_prototype 0)

# Generate UF2 + map + bin in addition to ELF
pico_add_extra_outputs(mezzanine_prototype)

# Print binary size after build
add_custom_command(TARGET mezzanine_prototype POST_BUILD
    COMMAND ${CMAKE_SIZE} $<TARGET_FILE:mezzanine_prototype>
)
