
# Variables
export ARCH=arm64
IMAGE=Image.gz-dtb
MODIMAGE=modules.img
DEFCONFIG=msm-perf_defconfig
BUILD_DATE=$(date -u +%m%d%Y)

# Paths
KERNEL_FOLDER=`pwd`
OUT_FOLDER="$KERNEL_FOLDER/out"
REPACK_FOLDER="$KERNEL_FOLDER/../anykernel"
MODULES_FOLDER="$REPACK_FOLDER/modules-img"
DATA_FOLDER="$REPACK_FOLDER/data"
TEMP_FOLDER="$REPACK_FOLDER/temporary"
TOOLCHAIN_FOLDER=/home/shivapeddi_sp/kernel/aarch64-linux-android-4.9/bin/aarch64-linux-android-
PRODUCT_FOLDER="$KERNEL_FOLDER/../products"

# Functions
function check_folders {
	if [ ! -d $OUT_FOLDER ]; then
		echo -e ${yellow}"Could not find output folder. Creating it..."${restore}
		echo -e ${green}"This folder is used to compile the Kernel out of the source code tree."${restore}
		mkdir -p $OUT_FOLDER
		echo ""
	fi;
	if [ ! -d $TOOLCHAIN_FOLDER ]; then
		# Fatal!
		echo -e ${red}"Could not find toolchains folder. Aborting..."${restore}
		echo -e ${yellow}"Read the readme.md for instructions."${restore}
		echo ""
		exit
	fi;
	if [ ! -d $REPACK_FOLDER ]; then
		# Fatal!
		echo -e ${red}"Could not find anykernel folder. Aborting..."${restore}
		echo -e ${yellow}"Read the readme.md for instructions."${restore}
		echo ""
		exit
	fi;
	if [ ! -d $MODULES_FOLDER ]; then
		echo -e ${yellow}"Could not find modules folder. Creating it..."${restore}
		echo -e ${green}"This folder is used to mount the loopback image to store the Kernel modules."${restore}
		mkdir -p $MODULES_FOLDER
		echo ""
	fi;
	if [ ! -d $TEMP_FOLDER ]; then
		echo -e ${yellow}"Could not find temporary folder. Creating it..."${restore}
		echo -e ${green}"This folder is used to strip down the Kernel modules."${restore}
		mkdir -p $TEMP_FOLDER
		echo ""
	fi;
	if [ ! -d $PRODUCT_FOLDER ]; then
		echo -e ${yellow}"Could not find products folder. Creating it..."${restore}
		mkdir -p $PRODUCT_FOLDER
		echo ""
	fi;
}

function checkout {
	# Check the proper AnyKernel2 branch.
	cd $REPACK_FOLDER
	git checkout $ANYBRANCH
	cd $KERNEL_FOLDER
	echo ""
}

function ccache_setup {
	if [ $USE_CCACHE == true ]; then
		CCACHE=`which ccache`
	else
		# Empty if USE_CCACHE is not set.
		CCACHE=""
	fi;
	echo -e ${yellow}"Ccache information:"${restore}
	# Print binary location as well if not empty.
	if [ ! -z "$CCACHE" ]; then
		echo "binary location                     $CCACHE"
	fi;
	# Show the more advanced ccache statistics.
	ccache -s
	echo ""
}

function prepare_bacon {
	# Make sure the local .config is gone.
	make mrproper
	if [ -f $OUT_FOLDER/Makefile ]; then
		# Clean everything inside output folder if dirty.
		cd $OUT_FOLDER
		make mrproper
		make clean
		cd $KERNEL_FOLDER
	fi;
	# We must remove the Image.gz-dtb manually if present.
	if [ -f $OUT_FOLDER/arch/$ARCH/boot/$IMAGE ]; then
		rm -fv $OUT_FOLDER/arch/$ARCH/boot/$IMAGE
	fi;
	# Remove the previous Kernel from anykernel folder if present.
	if [ -f $REPACK_FOLDER/$IMAGE ]; then
		rm -fv $REPACK_FOLDER/$IMAGE
	fi;
	# Remove all modules inside temporary folder unconditionally.
	rm -fv $TEMP_FOLDER/*
	# Remove the previous modules image if present.
	if [ -f $DATA_FOLDER/$MODIMAGE ]; then
		rm -fv $DATA_FOLDER/$MODIMAGE
	fi;
	echo ""
	echo -e ${green}"Everything is ready to start..."${restore}
}

function mka_bacon {
	# Clone the source to to output folder and compile over there.
	make -C "$KERNEL_FOLDER" O="$OUT_FOLDER" "$DEFCONFIG"
	make -C "$KERNEL_FOLDER" O="$OUT_FOLDER" "$THREAD"
}

function check_kernel {
	if [ -f $OUT_FOLDER/arch/$ARCH/boot/$IMAGE ]; then
		COMPILATION=sucesss
	else
		# If there's no image, the compilation may have failed.
		COMPILATION=sucks
	fi;
}

function mka_module {
	# Copy the modules to temporary folder to be stripped.
	for i in $(find "$OUT_FOLDER" -name '*.ko'); do
		cp -av "$i" $TEMP_FOLDER/
	done;
	# Strip debugging symbols from modules.
	$STRIP --strip-debug $TEMP_FOLDER/*
	# Give all modules R/W permissions.
	chmod 755 $TEMP_FOLDER/*
	# Create the EXT4 modules image and tune its parameters.
	dd if=/dev/zero of=$REPACK_FOLDER/$MODIMAGE bs=4k count=3000
	mkfs.ext4 $REPACK_FOLDER/$MODIMAGE
	tune2fs -c0 -i0 $REPACK_FOLDER/$MODIMAGE
	echo ""
	echo -e ${red}"Root is needed to use mount, chown and umount commands."${restore}
	# Mount empty modules image to insert the modules.
	sudo mount -o loop $REPACK_FOLDER/$MODIMAGE $MODULES_FOLDER
	# Change the owner to the normal user account so we can copy without 'sudo'.
	sudo chown $USER:$USER -R $MODULES_FOLDER
	# Copy the stripped modules to the image folder.
	for i in $(find "$TEMP_FOLDER" -name '*.ko'); do
		cp -av "$i" $MODULES_FOLDER/;
	done;
	if [ -f $MODULES_FOLDER/wlan.ko ]; then
		# Create qca_cld_wlan.ko linking to the original wlan.ko module.
		echo ""
		echo -e ${yellow}"Creating qca_cld_wlan.ko module symlink..."${restore}
		mkdir -p $MODULES_FOLDER/qca_cld
		cd $MODULES_FOLDER/qca_cld
		ln -s -f /system/lib/modules/wlan.ko qca_cld_wlan.ko
		cd $KERNEL_FOLDER
	fi;
	# Sync after we're done.
	sync
}

function mka_package {
	# Copy the new Kernel to the repack folder.
	cp -fv $OUT_FOLDER/arch/$ARCH/boot/$IMAGE $REPACK_FOLDER/$IMAGE
	# Only modular Kernel needs modules in /system/lib/modules.
	if [ "$FMODULE" = yes ]; then
		# Create the modules.img in this case and copy it to /data.
		mka_module
	fi;
	# Show images statistics.
	if [ -f $REPACK_FOLDER/$MODIMAGE ]; then
		echo ""
		echo -e ${yellow}"Modules image statistics:"${restore}
		stat $REPACK_FOLDER/$MODIMAGE
		echo ""
		echo -e ${yellow}"Modules image size:"${restore}
		du -sh $REPACK_FOLDER/$MODIMAGE
		# Move the modules image to /data.
		mv $REPACK_FOLDER/$MODIMAGE $DATA_FOLDER/$MODIMAGE
	fi;
	if [ -f $REPACK_FOLDER/$IMAGE ]; then
		echo ""
		echo -e ${yellow}"Kernel image statistics:"${restore}
		stat $REPACK_FOLDER/$IMAGE
		echo ""
		echo -e ${yellow}"Kernel image size:"${restore}
		du -sh $REPACK_FOLDER/$IMAGE
	fi;
}

function zip_package {
	cd $REPACK_FOLDER
	# Make sure everything is settled before zipping.
	echo -e ${yellow}"Please, wait 10 seconds..."${restore}
	if [ "$FMODULE" = yes ]; then
		# Unmount the modules folder with 'sudo' as well.
		sudo umount -v modules-img
	fi;
	sleep 10 && zip -x@zipexclude -r9 ${ZIPFILE}.zip *
	echo ""
	echo -e ${green}"Successfully built ${ZIPFILE}.zip."${restore}
	# Move the zip file to the 'products' folder to be stored and safe.
	mv ${ZIPFILE}.zip $PRODUCT_FOLDER/
	cd $PRODUCT_FOLDER
	# Create an md5sum file to be checked in recovery.
	md5sum ${ZIPFILE}.zip > ${ZIPFILE}.zip.md5sum
	cd $KERNEL_FOLDER
}

if [ $USE_CCACHE == true ]; then
	ccache_setup
else
	echo -e ${blue}"Optional:"${restore}
	echo -e ${yellow}"Add 'export USE_CCACHE=true' to your shell configuration to enable ccache."${restore}
	echo ""
fi;
