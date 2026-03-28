/**
 * CNN MNIST Real-time Digit Recognition with Pcam-5C
 *
 * Based on Digilent Pcam-5C demo application.
 * Added: CNN result polling via AXI-Lite + UART output.
 *
 * Hardware: Zybo Z7-20 + Pcam-5C
 * CNN: LeNet-style 3-layer CNN (28x28 grayscale -> digit 0~9)
 */

#include "xparameters.h"
#include "xil_io.h"
#include "sleep.h"

#include "platform/platform.h"
#include "ov5640/OV5640.h"
#include "ov5640/ScuGicInterruptController.h"
#include "ov5640/PS_GPIO.h"
#include "ov5640/AXI_VDMA.h"
#include "ov5640/PS_IIC.h"

#include "MIPI_D_PHY_RX.h"
#include "MIPI_CSI_2_RX.h"

/* ===== Device IDs ===== */
#define IRPT_CTL_DEVID      XPAR_PS7_SCUGIC_0_DEVICE_ID
#define GPIO_DEVID           XPAR_PS7_GPIO_0_DEVICE_ID
#define GPIO_IRPT_ID         XPAR_PS7_GPIO_0_INTR
#define CAM_I2C_DEVID        XPAR_PS7_I2C_0_DEVICE_ID
#define CAM_I2C_IRPT_ID      XPAR_PS7_I2C_0_INTR
#define VDMA_DEVID           XPAR_AXIVDMA_0_DEVICE_ID
#define VDMA_MM2S_IRPT_ID    XPAR_FABRIC_AXI_VDMA_0_MM2S_INTROUT_INTR
#define VDMA_S2MM_IRPT_ID    XPAR_FABRIC_AXI_VDMA_0_S2MM_INTROUT_INTR
#define CAM_I2C_SCLK_RATE    100000

#define DDR_BASE_ADDR        XPAR_DDR_MEM_BASEADDR
#define MEM_BASE_ADDR        (DDR_BASE_ADDR + 0x0A000000)
#define GAMMA_BASE_ADDR      XPAR_AXI_GAMMACORRECTION_0_BASEADDR

/* ===== CNN AXI-Lite Register Map ===== */
#define CNN_BASE_ADDR        0x40000000
#define CNN_REG_PREDICTION   (CNN_BASE_ADDR + 0x00)  /* 0~9 */
#define CNN_REG_PROBABILITY  (CNN_BASE_ADDR + 0x04)  /* 0~1023 */
#define CNN_REG_STATUS       (CNN_BASE_ADDR + 0x08)  /* bit0 = valid */

/* ===== CNN polling interval ===== */
#define CNN_POLL_INTERVAL_US  200000  /* 200ms */

using namespace digilent;

void pipeline_mode_change(AXI_VDMA<ScuGicInterruptController>& vdma_driver,
                          OV5640& cam, VideoOutput& vid,
                          Resolution res, OV5640_cfg::mode_t mode)
{
    /* Bring up input pipeline back-to-front */
    {
        vdma_driver.resetWrite();
        MIPI_CSI_2_RX_mWriteReg(XPAR_MIPI_CSI_2_RX_0_S_AXI_LITE_BASEADDR, CR_OFFSET,
                                (CR_RESET_MASK & ~CR_ENABLE_MASK));
        MIPI_D_PHY_RX_mWriteReg(XPAR_MIPI_D_PHY_RX_0_S_AXI_LITE_BASEADDR, CR_OFFSET,
                                (CR_RESET_MASK & ~CR_ENABLE_MASK));
        cam.reset();
    }

    {
        vdma_driver.configureWrite(timing[static_cast<int>(res)].h_active,
                                   timing[static_cast<int>(res)].v_active);
        Xil_Out32(GAMMA_BASE_ADDR, 3);  /* Gamma = 1/1.8 */
        cam.init();
    }

    {
        vdma_driver.enableWrite();
        MIPI_CSI_2_RX_mWriteReg(XPAR_MIPI_CSI_2_RX_0_S_AXI_LITE_BASEADDR, CR_OFFSET, CR_ENABLE_MASK);
        MIPI_D_PHY_RX_mWriteReg(XPAR_MIPI_D_PHY_RX_0_S_AXI_LITE_BASEADDR, CR_OFFSET, CR_ENABLE_MASK);
        cam.set_mode(mode);
        cam.set_awb(OV5640_cfg::awb_t::AWB_ADVANCED);
    }

    /* Bring up output pipeline back-to-front */
    {
        vid.reset();
        vdma_driver.resetRead();
    }

    {
        vid.configure(res);
        vdma_driver.configureRead(timing[static_cast<int>(res)].h_active,
                                  timing[static_cast<int>(res)].v_active);
    }

    {
        vid.enable();
        vdma_driver.enableRead();
    }
}

int main()
{
    init_platform();

    xil_printf("\r\n====================================\r\n");
    xil_printf("  CNN MNIST Real-time Recognition\r\n");
    xil_printf("  Zybo Z7-20 + Pcam-5C\r\n");
    xil_printf("====================================\r\n\r\n");

    /* Initialize Pcam pipeline */
    ScuGicInterruptController irpt_ctl(IRPT_CTL_DEVID);
    PS_GPIO<ScuGicInterruptController> gpio_driver(GPIO_DEVID, irpt_ctl, GPIO_IRPT_ID);
    PS_IIC<ScuGicInterruptController> iic_driver(CAM_I2C_DEVID, irpt_ctl, CAM_I2C_IRPT_ID, 100000);

    OV5640 cam(iic_driver, gpio_driver);
    AXI_VDMA<ScuGicInterruptController> vdma_driver(VDMA_DEVID, MEM_BASE_ADDR, irpt_ctl,
            VDMA_MM2S_IRPT_ID,
            VDMA_S2MM_IRPT_ID);
    VideoOutput vid(XPAR_VTC_0_DEVICE_ID, XPAR_VIDEO_DYNCLK_DEVICE_ID);

    /* Start camera at 720p 60fps */
    pipeline_mode_change(vdma_driver, cam, vid,
                         Resolution::R1280_720_60_PP,
                         OV5640_cfg::mode_t::MODE_720P_1280_720_60fps);

    xil_printf("Video pipeline initialized (720p 60fps).\r\n");
    xil_printf("CNN inference running in hardware...\r\n\r\n");

    /* Main loop: poll CNN results */
    u32 prev_prediction = 99;
    u32 frame_count = 0;

    while (1) {
        u32 prediction  = Xil_In32(CNN_REG_PREDICTION);
        u32 probability = Xil_In32(CNN_REG_PROBABILITY);
        u32 status      = Xil_In32(CNN_REG_STATUS);

        /* Convert probability to percentage (0~1023 -> 0~100%) */
        u32 percent = (probability * 100) / 1023;

        frame_count++;

        if (status & 0x01) {
            /* Print every poll, highlight changes */
            if (prediction != prev_prediction) {
                xil_printf("\r\n>> NEW DIGIT DETECTED <<\r\n");
                prev_prediction = prediction;
            }

            xil_printf("[%06d] Digit: %d  Confidence: %d%%  (raw: %d/1023)\r\n",
                       frame_count, prediction, percent, probability);
        }

        usleep(CNN_POLL_INTERVAL_US);
    }

    cleanup_platform();
    return 0;
}
