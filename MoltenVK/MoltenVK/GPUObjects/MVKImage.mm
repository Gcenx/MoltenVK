/*
 * MVKImage.mm
 *
 * Copyright (c) 2014-2019 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKImage.h"
#include "MVKSwapchain.h"
#include "MVKCommandBuffer.h"
#include "mvk_datatypes.h"
#include "MVKFoundation.h"
#include "MVKEnvironment.h"
#include "MVKLogging.h"
#include "MVKCodec.h"
#import "MTLTextureDescriptor+MoltenVK.h"
#import "MTLSamplerDescriptor+MoltenVK.h"

using namespace std;


#pragma mark MVKImage

VkImageType MVKImage::getImageType() { return mvkVkImageTypeFromMTLTextureType(_mtlTextureType); }

VkFormat MVKImage::getVkFormat() { return mvkVkFormatFromMTLPixelFormat(_mtlPixelFormat); }

VkExtent3D MVKImage::getExtent3D(uint32_t mipLevel) {
	return mvkMipmapLevelSizeFromBaseSize3D(_extent, mipLevel);
}

VkDeviceSize MVKImage::getBytesPerRow(uint32_t mipLevel) {
    size_t bytesPerRow = mvkMTLPixelFormatBytesPerRow(_mtlPixelFormat, getExtent3D(mipLevel).width);
    return (uint32_t)mvkAlignByteOffset(bytesPerRow, _byteAlignment);
}

VkDeviceSize MVKImage::getBytesPerLayer(uint32_t mipLevel) {
    return mvkMTLPixelFormatBytesPerLayer(_mtlPixelFormat, getBytesPerRow(mipLevel), getExtent3D(mipLevel).height);
}

VkResult MVKImage::getSubresourceLayout(const VkImageSubresource* pSubresource,
										VkSubresourceLayout* pLayout) {
	MVKImageSubresource* pImgRez = getSubresource(pSubresource->mipLevel,
												  pSubresource->arrayLayer);
	if ( !pImgRez ) { return VK_INCOMPLETE; }

	*pLayout = pImgRez->layout;
	return VK_SUCCESS;
}

void MVKImage::getTransferDescriptorData(MVKImageDescriptorData& imgData) {
    imgData.imageType = getImageType();
    imgData.format = getVkFormat();
    imgData.extent = _extent;
    imgData.mipLevels = _mipLevels;
    imgData.arrayLayers = _arrayLayers;
    imgData.samples = _samples;
    imgData.usage = _usage;
}


#pragma mark Resource memory

void MVKImage::applyMemoryBarrier(VkPipelineStageFlags srcStageMask,
								  VkPipelineStageFlags dstStageMask,
								  VkMemoryBarrier* pMemoryBarrier,
                                  MVKCommandEncoder* cmdEncoder,
                                  MVKCommandUse cmdUse) {
#if MVK_MACOS
	if ( needsHostReadSync(srcStageMask, dstStageMask, pMemoryBarrier) ) {
		[cmdEncoder->getMTLBlitEncoder(cmdUse) synchronizeResource: getMTLTexture()];
	}
#endif
}

void MVKImage::applyImageMemoryBarrier(VkPipelineStageFlags srcStageMask,
									   VkPipelineStageFlags dstStageMask,
									   VkImageMemoryBarrier* pImageMemoryBarrier,
                                       MVKCommandEncoder* cmdEncoder,
                                       MVKCommandUse cmdUse) {
	const VkImageSubresourceRange& srRange = pImageMemoryBarrier->subresourceRange;

	// Extract the mipmap levels that are to be updated
	uint32_t mipLvlStart = srRange.baseMipLevel;
	uint32_t mipLvlCnt = srRange.levelCount;
	uint32_t mipLvlEnd = (mipLvlCnt == VK_REMAINING_MIP_LEVELS
						  ? getMipLevelCount()
						  : (mipLvlStart + mipLvlCnt));

	// Extract the cube or array layers (slices) that are to be updated
	uint32_t layerStart = srRange.baseArrayLayer;
	uint32_t layerCnt = srRange.layerCount;
	uint32_t layerEnd = (layerCnt == VK_REMAINING_ARRAY_LAYERS
						 ? getLayerCount()
						 : (layerStart + layerCnt));

#if MVK_MACOS
	bool needsSync = needsHostReadSync(srcStageMask, dstStageMask, pImageMemoryBarrier);
	id<MTLTexture> mtlTex = needsSync ? getMTLTexture() : nil;
	id<MTLBlitCommandEncoder> mtlBlitEncoder = needsSync ? cmdEncoder->getMTLBlitEncoder(cmdUse) : nil;
#endif

	// Iterate across mipmap levels and layers, and update the image layout state for each
	for (uint32_t mipLvl = mipLvlStart; mipLvl < mipLvlEnd; mipLvl++) {
		for (uint32_t layer = layerStart; layer < layerEnd; layer++) {
			MVKImageSubresource* pImgRez = getSubresource(mipLvl, layer);
			if (pImgRez) { pImgRez->layoutState = pImageMemoryBarrier->newLayout; }
#if MVK_MACOS
			if (needsSync) { [mtlBlitEncoder synchronizeTexture: mtlTex slice: layer level: mipLvl]; }
#endif
		}
	}
}

// Returns whether the specified image memory barrier requires a sync between this
// texture and host memory for the purpose of the host reading texture memory.
bool MVKImage::needsHostReadSync(VkPipelineStageFlags srcStageMask,
								 VkPipelineStageFlags dstStageMask,
								 VkImageMemoryBarrier* pImageMemoryBarrier) {
#if MVK_IOS
	return false;
#endif
#if MVK_MACOS
	return ((pImageMemoryBarrier->newLayout == VK_IMAGE_LAYOUT_GENERAL) &&
			mvkIsAnyFlagEnabled(dstStageMask, (VK_PIPELINE_STAGE_HOST_BIT)) &&
			mvkIsAnyFlagEnabled(pImageMemoryBarrier->dstAccessMask, (VK_ACCESS_HOST_READ_BIT)) &&
			isMemoryHostAccessible() && !isMemoryHostCoherent());
#endif
}

// Returns a pointer to the internal subresource for the specified MIP level layer.
MVKImageSubresource* MVKImage::getSubresource(uint32_t mipLevel, uint32_t arrayLayer) {
	uint32_t srIdx = (mipLevel * _arrayLayers) + arrayLayer;
	return (srIdx < _subresources.size()) ? &_subresources[srIdx] : NULL;
}

VkResult MVKImage::getMemoryRequirements(VkMemoryRequirements* pMemoryRequirements) {
	pMemoryRequirements->size = _byteCount;
	pMemoryRequirements->alignment = _byteAlignment;
	pMemoryRequirements->memoryTypeBits = (_isDepthStencilAttachment
										   ? _device->getPhysicalDevice()->getPrivateMemoryTypes()
										   : _device->getPhysicalDevice()->getAllMemoryTypes());
#if MVK_MACOS
	if (!_isLinear) {  // XXX Linear images must support host-coherent memory
		mvkDisableFlag(pMemoryRequirements->memoryTypeBits, _device->getPhysicalDevice()->getHostCoherentMemoryTypes());
	}
#endif
#if MVK_IOS
	// Only transient attachments may use memoryless storage
	if (!mvkAreFlagsEnabled(_usage, VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT) ) {
		mvkDisableFlag(pMemoryRequirements->memoryTypeBits, _device->getPhysicalDevice()->getLazilyAllocatedMemoryTypes());
	}
#endif
	return VK_SUCCESS;
}

VkResult MVKImage::getMemoryRequirements(const void*, VkMemoryRequirements2* pMemoryRequirements) {
	pMemoryRequirements->sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2;
	getMemoryRequirements(&pMemoryRequirements->memoryRequirements);
	auto* next = (VkStructureType*)pMemoryRequirements->pNext;
	while (next) {
		switch (*next) {
		case VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS: {
			auto* dedicatedReqs = (VkMemoryDedicatedRequirements*)next;
			// TODO: Maybe someday we could do something with MTLHeaps
			// and allocate non-dedicated memory from them. For now, we
			// always prefer dedicated allocations.
			dedicatedReqs->prefersDedicatedAllocation = VK_TRUE;
			dedicatedReqs->requiresDedicatedAllocation = VK_FALSE;
			next = (VkStructureType*)dedicatedReqs->pNext;
			break;
		}
		default:
			next = (VkStructureType*)((VkMemoryRequirements2*)next)->pNext;
			break;
		}
	}
	return VK_SUCCESS;
}

// Memory may have been mapped before image was bound, and needs to be loaded into the MTLTexture.
VkResult MVKImage::bindDeviceMemory(MVKDeviceMemory* mvkMem, VkDeviceSize memOffset) {
	if (_deviceMemory) { _deviceMemory->removeImage(this); }

	MVKResource::bindDeviceMemory(mvkMem, memOffset);

	_usesTexelBuffer = validateUseTexelBuffer();

	flushToDevice(getDeviceMemoryOffset(), getByteCount());

	return _deviceMemory ? _deviceMemory->addImage(this) : VK_SUCCESS;
}

bool MVKImage::validateUseTexelBuffer() {
	VkExtent2D blockExt = mvkMTLPixelFormatBlockTexelSize(_mtlPixelFormat);
	bool isUncompressed = blockExt.width == 1 && blockExt.height == 1;

	bool useTexelBuffer = _device->_pMetalFeatures->texelBuffers;								// Texel buffers available
	useTexelBuffer = useTexelBuffer && isMemoryHostAccessible() && _isLinear && isUncompressed;	// Applicable memory layout
	useTexelBuffer = useTexelBuffer && _deviceMemory && _deviceMemory->_mtlBuffer;				// Buffer is available to overlay

#if MVK_MACOS
	useTexelBuffer = useTexelBuffer && !isMemoryHostCoherent();	// macOS cannot use shared memory for texel buffers
#endif

	return useTexelBuffer;
}

bool MVKImage::shouldFlushHostMemory() { return isMemoryHostAccessible() && !_usesTexelBuffer; }

// Flushes the device memory at the specified memory range into the MTLTexture. Updates
// all subresources that overlap the specified range and are in an updatable layout state.
VkResult MVKImage::flushToDevice(VkDeviceSize offset, VkDeviceSize size) {
	if (shouldFlushHostMemory()) {
		for (auto& subRez : _subresources) {
			switch (subRez.layoutState) {
				case VK_IMAGE_LAYOUT_UNDEFINED:
				case VK_IMAGE_LAYOUT_PREINITIALIZED:
				case VK_IMAGE_LAYOUT_GENERAL: {
					updateMTLTextureContent(subRez, offset, size);
					break;
				}
				default:
					break;
			}
		}
	}
	return VK_SUCCESS;
}

// Pulls content from the MTLTexture into the device memory at the specified memory range.
// Pulls from all subresources that overlap the specified range and are in an updatable layout state.
VkResult MVKImage::pullFromDevice(VkDeviceSize offset, VkDeviceSize size) {
	if (shouldFlushHostMemory()) {
		for (auto& subRez : _subresources) {
			switch (subRez.layoutState) {
				case VK_IMAGE_LAYOUT_GENERAL: {
					getMTLTextureContent(subRez, offset, size);
					break;
				}
				default:
					break;
			}
		}
	}
	return VK_SUCCESS;
}


#pragma mark Metal

id<MTLTexture> MVKImage::getMTLTexture() {
	if ( !_mtlTexture && _mtlPixelFormat ) {

		// Lock and check again in case another thread has created the texture.
		lock_guard<mutex> lock(_lock);
		if (_mtlTexture) { return _mtlTexture; }

		_mtlTexture = newMTLTexture();   // retained
	}
	return _mtlTexture;
}

VkResult MVKImage::setMTLTexture(id<MTLTexture> mtlTexture) {
    lock_guard<mutex> lock(_lock);
    resetMTLTexture();
    resetIOSurface();

    _mtlTexture = [mtlTexture retain];		// retained

    _mtlPixelFormat = _mtlTexture.pixelFormat;
    _mtlTextureType = _mtlTexture.textureType;
    _extent.width = uint32_t(_mtlTexture.width);
    _extent.height = uint32_t(_mtlTexture.height);
    _extent.depth = uint32_t(_mtlTexture.depth);
    _mipLevels = uint32_t(_mtlTexture.mipmapLevelCount);
    _samples = mvkVkSampleCountFlagBitsFromSampleCount(_mtlTexture.sampleCount);
    _arrayLayers = uint32_t(_mtlTexture.arrayLength);
    _usage = mvkVkImageUsageFlagsFromMTLTextureUsage(_mtlTexture.usage, _mtlPixelFormat);

    if (_device->_pMetalFeatures->ioSurfaces) {
        _ioSurface = mtlTexture.iosurface;
        CFRetain(_ioSurface);
    }

    return VK_SUCCESS;
}

// Creates and returns a retained Metal texture suitable for use in this instance.
// This implementation creates a new MTLTexture from a MTLTextureDescriptor and possible IOSurface.
// Subclasses may override this function to create the MTLTexture in a different manner.
id<MTLTexture> MVKImage::newMTLTexture() {
    if (_ioSurface) {
        return [getMTLDevice() newTextureWithDescriptor: getMTLTextureDescriptor() iosurface: _ioSurface plane: 0];
	} else if (_usesTexelBuffer) {
        return [_deviceMemory->_mtlBuffer newTextureWithDescriptor: getMTLTextureDescriptor()
															offset: getDeviceMemoryOffset()
													   bytesPerRow: _subresources[0].layout.rowPitch];
    } else {
        return [getMTLDevice() newTextureWithDescriptor: getMTLTextureDescriptor()];
    }
}

// Removes and releases the MTLTexture object, so that it can be lazily created by getMTLTexture().
void MVKImage::resetMTLTexture() {
	[_mtlTexture release];
	_mtlTexture = nil;
}

void MVKImage::resetIOSurface() {
    if (_ioSurface) {
        CFRelease(_ioSurface);
        _ioSurface = nil;
    }
}

IOSurfaceRef MVKImage::getIOSurface() { return _ioSurface; }

VkResult MVKImage::useIOSurface(IOSurfaceRef ioSurface) {

    if (!_device->_pMetalFeatures->ioSurfaces) { return mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkUseIOSurfaceMVK() : IOSurfaces are not supported on this platform."); }

#if MVK_SUPPORT_IOSURFACE_BOOL

    resetMTLTexture();
    resetIOSurface();

    if (ioSurface) {
		if (IOSurfaceGetWidth(ioSurface) != _extent.width) { return mvkNotifyErrorWithText(VK_ERROR_INITIALIZATION_FAILED, "vkUseIOSurfaceMVK() : IOSurface width %zu does not match VkImage width %d.", IOSurfaceGetWidth(ioSurface), _extent.width); }
		if (IOSurfaceGetHeight(ioSurface) != _extent.height) { return mvkNotifyErrorWithText(VK_ERROR_INITIALIZATION_FAILED, "vkUseIOSurfaceMVK() : IOSurface height %zu does not match VkImage height %d.", IOSurfaceGetHeight(ioSurface), _extent.height); }
		if (IOSurfaceGetBytesPerElement(ioSurface) != mvkMTLPixelFormatBytesPerBlock(_mtlPixelFormat)) { return mvkNotifyErrorWithText(VK_ERROR_INITIALIZATION_FAILED, "vkUseIOSurfaceMVK() : IOSurface bytes per element %zu does not match VkImage bytes per element %d.", IOSurfaceGetBytesPerElement(ioSurface), mvkMTLPixelFormatBytesPerBlock(_mtlPixelFormat)); }
		if (IOSurfaceGetElementWidth(ioSurface) != mvkMTLPixelFormatBlockTexelSize(_mtlPixelFormat).width) { return mvkNotifyErrorWithText(VK_ERROR_INITIALIZATION_FAILED, "vkUseIOSurfaceMVK() : IOSurface element width %zu does not match VkImage element width %d.", IOSurfaceGetElementWidth(ioSurface), mvkMTLPixelFormatBlockTexelSize(_mtlPixelFormat).width); }
		if (IOSurfaceGetElementHeight(ioSurface) != mvkMTLPixelFormatBlockTexelSize(_mtlPixelFormat).height) { return mvkNotifyErrorWithText(VK_ERROR_INITIALIZATION_FAILED, "vkUseIOSurfaceMVK() : IOSurface element height %zu does not match VkImage element height %d.", IOSurfaceGetElementHeight(ioSurface), mvkMTLPixelFormatBlockTexelSize(_mtlPixelFormat).height); }

        _ioSurface = ioSurface;
        CFRetain(_ioSurface);
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        _ioSurface = IOSurfaceCreate((CFDictionaryRef)@{
                                                        (id)kIOSurfaceWidth: @(_extent.width),
                                                        (id)kIOSurfaceHeight: @(_extent.height),
                                                        (id)kIOSurfaceBytesPerElement: @(mvkMTLPixelFormatBytesPerBlock(_mtlPixelFormat)),
                                                        (id)kIOSurfaceElementWidth: @(mvkMTLPixelFormatBlockTexelSize(_mtlPixelFormat).width),
                                                        (id)kIOSurfaceElementHeight: @(mvkMTLPixelFormatBlockTexelSize(_mtlPixelFormat).height),
                                                        (id)kIOSurfaceIsGlobal: @(true),    // Deprecated but needed for interprocess transfers
                                                        });
#pragma clang diagnostic pop

    }

#endif

    return VK_SUCCESS;
}

MTLTextureUsage MVKImage::getMTLTextureUsage() {
	MTLTextureUsage usage = mvkMTLTextureUsageFromVkImageUsageFlags(_usage);

	// If this is a depth/stencil texture, and the device supports it, tell
	// Metal we may create texture views of this, too.
	if ((_mtlPixelFormat == MTLPixelFormatDepth32Float_Stencil8
#if MVK_MACOS
		 || _mtlPixelFormat == MTLPixelFormatDepth24Unorm_Stencil8
#endif
		) && _device->_pMetalFeatures->stencilViews) {
		mvkEnableFlag(usage, MTLTextureUsagePixelFormatView);
	}

	// If this format doesn't support being blitted to, and the usage
	// doesn't specify use as an attachment, turn off
	// MTLTextureUsageRenderTarget.
	VkFormatProperties props;
	_device->getPhysicalDevice()->getFormatProperties(getVkFormat(), &props);
	if (!mvkAreFlagsEnabled(_isLinear ? props.linearTilingFeatures : props.optimalTilingFeatures, VK_FORMAT_FEATURE_BLIT_DST_BIT) &&
		!mvkIsAnyFlagEnabled(_usage, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)) {
		mvkDisableFlag(usage, MTLTextureUsageRenderTarget);
	}

#if MVK_MACOS
	// If this is a 3D compressed texture, tell Metal we might write to it.
	if (_is3DCompressed) {
		mvkEnableFlag(usage, MTLTextureUsageShaderWrite);
	}
#endif

	return usage;
}

// Returns an autoreleased Metal texture descriptor constructed from the properties of this image.
MTLTextureDescriptor* MVKImage::getMTLTextureDescriptor() {
	MTLTextureDescriptor* mtlTexDesc = [[MTLTextureDescriptor alloc] init];
#if MVK_MACOS
	if (_is3DCompressed) {
		// Metal doesn't yet support 3D compressed textures, so we'll decompress
		// the texture ourselves. This, then, is the *uncompressed* format.
		mtlTexDesc.pixelFormat = MTLPixelFormatBGRA8Unorm;
	} else {
		mtlTexDesc.pixelFormat = _mtlPixelFormat;
	}
#else
	mtlTexDesc.pixelFormat = _mtlPixelFormat;
#endif
	mtlTexDesc.textureType = _mtlTextureType;
	mtlTexDesc.width = _extent.width;
	mtlTexDesc.height = _extent.height;
	mtlTexDesc.depth = _extent.depth;
	mtlTexDesc.mipmapLevelCount = _mipLevels;
	mtlTexDesc.sampleCount = mvkSampleCountFromVkSampleCountFlagBits(_samples);
	mtlTexDesc.arrayLength = _arrayLayers;
	mtlTexDesc.usageMVK = getMTLTextureUsage();
	mtlTexDesc.storageModeMVK = getMTLStorageMode();
	mtlTexDesc.cpuCacheMode = getMTLCPUCacheMode();

	return [mtlTexDesc autorelease];
}

MTLStorageMode MVKImage::getMTLStorageMode() {
    // For macOS, textures cannot use Shared storage mode, so change to Managed storage mode.
    MTLStorageMode stgMode = _deviceMemory->getMTLStorageMode();

    if (_ioSurface && stgMode == MTLStorageModePrivate) { stgMode = MTLStorageModeShared; }

#if MVK_MACOS
    if (stgMode == MTLStorageModeShared) { stgMode = MTLStorageModeManaged; }
#endif
    return stgMode;
}

// Updates the contents of the underlying MTLTexture, corresponding to the
// specified subresource definition, from the underlying memory buffer.
void MVKImage::updateMTLTextureContent(MVKImageSubresource& subresource,
                                       VkDeviceSize offset, VkDeviceSize size) {

	VkImageSubresource& imgSubRez = subresource.subresource;
	VkSubresourceLayout& imgLayout = subresource.layout;

	// Check if subresource overlaps the memory range.
    VkDeviceSize memStart = offset;
    VkDeviceSize memEnd = offset + size;
    VkDeviceSize imgStart = imgLayout.offset;
    VkDeviceSize imgEnd = imgLayout.offset + imgLayout.size;
    if (imgStart >= memEnd || imgEnd <= memStart) { return; }

	// Don't update if host memory has not been mapped yet.
	void* pHostMem = getHostMemoryAddress();
	if ( !pHostMem ) { return; }

    VkExtent3D mipExtent = getExtent3D(imgSubRez.mipLevel);
    VkImageType imgType = getImageType();
    void* pImgBytes = (void*)((uintptr_t)pHostMem + imgLayout.offset);

    MTLRegion mtlRegion;
    mtlRegion.origin = MTLOriginMake(0, 0, 0);
    mtlRegion.size = mvkMTLSizeFromVkExtent3D(mipExtent);

#if MVK_MACOS
    std::unique_ptr<char[]> decompBuffer;
    if (_is3DCompressed) {
        // We cannot upload the texture data directly in this case. But we
        // can upload the decompressed image data.
        std::unique_ptr<MVKCodec> codec = mvkCreateCodec(getVkFormat());
        if (!codec) {
            mvkNotifyErrorWithText(VK_ERROR_FORMAT_NOT_SUPPORTED, "A 3D texture used a compressed format that MoltenVK does not yet support.");
            return;
        }
        VkSubresourceLayout destLayout;
        destLayout.rowPitch = 4 * mipExtent.width;
        destLayout.depthPitch = destLayout.rowPitch * mipExtent.height;
        destLayout.size = destLayout.depthPitch * mipExtent.depth;
        decompBuffer = std::unique_ptr<char[]>(new char[destLayout.size]);
        codec->decompress(decompBuffer.get(), pImgBytes, destLayout, imgLayout, mipExtent);
        pImgBytes = decompBuffer.get();
        imgLayout = destLayout;
    }
#endif

	VkDeviceSize bytesPerRow = (imgType != VK_IMAGE_TYPE_1D) ? imgLayout.rowPitch : 0;
	VkDeviceSize bytesPerImage = (imgType == VK_IMAGE_TYPE_3D) ? imgLayout.depthPitch : 0;

	id<MTLTexture> mtlTex = getMTLTexture();
	if (mvkMTLPixelFormatIsPVRTCFormat(mtlTex.pixelFormat)) {
		bytesPerRow = 0;
		bytesPerImage = 0;
	}

	[mtlTex replaceRegion: mtlRegion
			  mipmapLevel: imgSubRez.mipLevel
					slice: imgSubRez.arrayLayer
				withBytes: pImgBytes
			  bytesPerRow: bytesPerRow
			bytesPerImage: bytesPerImage];
}

// Updates the contents of the underlying memory buffer from the contents of
// the underlying MTLTexture, corresponding to the specified subresource definition.
void MVKImage::getMTLTextureContent(MVKImageSubresource& subresource,
                                    VkDeviceSize offset, VkDeviceSize size) {

	VkImageSubresource& imgSubRez = subresource.subresource;
	VkSubresourceLayout& imgLayout = subresource.layout;

	// Check if subresource overlaps the memory range.
    VkDeviceSize memStart = offset;
    VkDeviceSize memEnd = offset + size;
    VkDeviceSize imgStart = imgLayout.offset;
    VkDeviceSize imgEnd = imgLayout.offset + imgLayout.size;
    if (imgStart >= memEnd || imgEnd <= memStart) { return; }

	// Don't update if host memory has not been mapped yet.
	void* pHostMem = getHostMemoryAddress();
	if ( !pHostMem ) { return; }

    VkExtent3D mipExtent = getExtent3D(imgSubRez.mipLevel);
    VkImageType imgType = getImageType();
    void* pImgBytes = (void*)((uintptr_t)pHostMem + imgLayout.offset);

    MTLRegion mtlRegion;
    mtlRegion.origin = MTLOriginMake(0, 0, 0);
    mtlRegion.size = mvkMTLSizeFromVkExtent3D(mipExtent);

    [getMTLTexture() getBytes: pImgBytes
                  bytesPerRow: (imgType != VK_IMAGE_TYPE_1D ? imgLayout.rowPitch : 0)
                bytesPerImage: (imgType == VK_IMAGE_TYPE_3D ? imgLayout.depthPitch : 0)
                   fromRegion: mtlRegion
                  mipmapLevel: imgSubRez.mipLevel
                        slice: imgSubRez.arrayLayer];
}


#pragma mark Construction

MVKImage::MVKImage(MVKDevice* device, const VkImageCreateInfo* pCreateInfo) : MVKResource(device) {

    if (pCreateInfo->flags & VK_IMAGE_CREATE_BLOCK_TEXEL_VIEW_COMPATIBLE_BIT) {
        setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : Metal does not allow uncompressed views of compressed images."));
    }

#if MVK_IOS
    if ( (pCreateInfo->imageType != VK_IMAGE_TYPE_2D) && (mvkFormatTypeFromVkFormat(pCreateInfo->format) == kMVKFormatCompressed) ) {
        setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : Under Metal, compressed formats may only be used with 2D images."));
    }
#else
    if ( (pCreateInfo->imageType != VK_IMAGE_TYPE_2D) && (mvkFormatTypeFromVkFormat(pCreateInfo->format) == kMVKFormatCompressed) && !mvkCanDecodeFormat(pCreateInfo->format) ) {
        setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : Under Metal, compressed formats may only be used with 2D images."));
    }
#endif
    if ( (pCreateInfo->imageType != VK_IMAGE_TYPE_2D) && (mvkFormatTypeFromVkFormat(pCreateInfo->format) == kMVKFormatDepthStencil) ) {
        setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : Under Metal, depth/stencil formats may only be used with 2D images."));
    }

    // Adjust the info components to be compatible with Metal, then use the modified versions
    // to set other config info. Vulkan allows unused extent dimensions to be zero, but Metal
    // requires minimum of one. Adjust samples and miplevels for the right texture type.
    uint32_t minDim = 1;
    _usage = pCreateInfo->usage;
    _extent.width = max(pCreateInfo->extent.width, minDim);
	_extent.height = max(pCreateInfo->extent.height, minDim);
	_extent.depth = max(pCreateInfo->extent.depth, minDim);
    _arrayLayers = max(pCreateInfo->arrayLayers, minDim);

    _mipLevels = max(pCreateInfo->mipLevels, minDim);
    if ( (_mipLevels > 1) && (pCreateInfo->imageType == VK_IMAGE_TYPE_1D) ) {
        setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : Under Metal, 1D images cannot use mipmaps. Setting mip levels to 1."));
        _mipLevels = 1;
    }

    _mtlTexture = nil;
    _ioSurface = nil;
    _mtlPixelFormat = getMTLPixelFormatFromVkFormat(pCreateInfo->format);
    _mtlTextureType = mvkMTLTextureTypeFromVkImageType(pCreateInfo->imageType,
                                                       _arrayLayers,
                                                       (pCreateInfo->samples > 1));
    _samples = pCreateInfo->samples;
    if ( (_samples > 1) && (_mtlTextureType != MTLTextureType2DMultisample) &&
         (pCreateInfo->imageType != VK_IMAGE_TYPE_2D || !_device->_pMetalFeatures->multisampleArrayTextures) ) {
        if (pCreateInfo->imageType != VK_IMAGE_TYPE_2D) {
            setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : Under Metal, multisampling can only be used with a 2D image type. Setting sample count to 1."));
        } else {
            setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : This version of Metal does not support multisampled array textures. Setting sample count to 1."));
        }
        _samples = VK_SAMPLE_COUNT_1_BIT;
        if (pCreateInfo->imageType == VK_IMAGE_TYPE_2D) {
            _mtlTextureType = MTLTextureType2DArray;
        }
    }
    if ( (_samples > 1) && (mvkFormatTypeFromVkFormat(pCreateInfo->format) == kMVKFormatCompressed) ) {
        setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : Under Metal, multisampling cannot be used with compressed images. Setting sample count to 1."));
        _samples = VK_SAMPLE_COUNT_1_BIT;
    }

    _isDepthStencilAttachment = (mvkAreFlagsEnabled(pCreateInfo->usage, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) ||
                                 mvkAreFlagsEnabled(mvkVkFormatProperties(pCreateInfo->format).optimalTilingFeatures, VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT));
	_canSupportMTLTextureView = !_isDepthStencilAttachment || _device->_pMetalFeatures->stencilViews;
    _hasExpectedTexelSize = (mvkMTLPixelFormatBytesPerBlock(_mtlPixelFormat) == mvkVkFormatBytesPerBlock(pCreateInfo->format));
	_isLinear = validateLinear(pCreateInfo);
	_usesTexelBuffer = false;
	_is3DCompressed = _mtlTextureType == MTLTextureType3D && mvkFormatTypeFromMTLPixelFormat(_mtlPixelFormat) == kMVKFormatCompressed;

	_byteAlignment = _isLinear ? _device->getVkFormatTexelBufferAlignment(pCreateInfo->format) : mvkEnsurePowerOfTwo(mvkVkFormatBytesPerBlock(pCreateInfo->format));

    // Calc _byteCount after _mtlTexture & _byteAlignment
    for (uint32_t mipLvl = 0; mipLvl < _mipLevels; mipLvl++) {
        _byteCount += getBytesPerLayer(mipLvl) * _extent.depth * _arrayLayers;
    }

    initSubresources(pCreateInfo);
}

bool MVKImage::validateLinear(const VkImageCreateInfo* pCreateInfo) {
	if (pCreateInfo->tiling != VK_IMAGE_TILING_LINEAR) { return false; }

	if (pCreateInfo->imageType != VK_IMAGE_TYPE_2D) {
		setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : If tiling is VK_IMAGE_TILING_LINEAR, imageType must be VK_IMAGE_TYPE_2D."));
		return false;
	}

	if (_isDepthStencilAttachment) {
		setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : If tiling is VK_IMAGE_TILING_LINEAR, format must not be a depth/stencil format."));
		return false;
	}

	if (_mipLevels > 1) {
		setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : If tiling is VK_IMAGE_TILING_LINEAR, mipLevels must be 1."));
		return false;
	}

	if (_arrayLayers > 1) {
		setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : If tiling is VK_IMAGE_TILING_LINEAR, arrayLayers must be 1."));
		return false;
	}

	if (_samples > 1) {
		setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : If tiling is VK_IMAGE_TILING_LINEAR, samples must be VK_SAMPLE_COUNT_1_BIT."));
		return false;
	}

#if MVK_MACOS
	if ( mvkIsAnyFlagEnabled(_usage, (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT | VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT)) ) {
		setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImage() : If tiling is VK_IMAGE_TILING_LINEAR, usage must not include VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT, and/or VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT."));
		return false;
	}
#endif

	return true;
}


// Initializes the subresource definitions.
void MVKImage::initSubresources(const VkImageCreateInfo* pCreateInfo) {
	_subresources.reserve(_mipLevels * _arrayLayers);

	MVKImageSubresource subRez;
	subRez.layoutState = pCreateInfo->initialLayout;

	for (uint32_t mipLvl = 0; mipLvl < _mipLevels; mipLvl++) {
		subRez.subresource.mipLevel = mipLvl;

		for (uint32_t layer = 0; layer < _arrayLayers; layer++) {
			subRez.subresource.arrayLayer = layer;
			initSubresourceLayout(subRez);
			_subresources.push_back(subRez);
		}
	}
}

// Initializes the layout element of the specified image subresource.
void MVKImage::initSubresourceLayout(MVKImageSubresource& imgSubRez) {
	VkImageSubresource subresource = imgSubRez.subresource;
	uint32_t currMipLevel = subresource.mipLevel;
	uint32_t currArrayLayer = subresource.arrayLayer;

	VkDeviceSize bytesPerLayerCurrLevel = getBytesPerLayer(currMipLevel);

	// Accumulate the byte offset for the specified sub-resource.
	// This is the sum of the bytes consumed by all layers in all mipmap levels before the
	// desired level, plus the layers before the desired layer at the desired level.
	VkDeviceSize offset = 0;
	for (uint32_t mipLvl = 0; mipLvl < currMipLevel; mipLvl++) {
		offset += (getBytesPerLayer(mipLvl) * _extent.depth * _arrayLayers);
	}
	offset += (bytesPerLayerCurrLevel * currArrayLayer);

	VkSubresourceLayout& layout = imgSubRez.layout;
	layout.offset = offset;
	layout.size = bytesPerLayerCurrLevel;
	layout.rowPitch = getBytesPerRow(currMipLevel);
	layout.depthPitch = bytesPerLayerCurrLevel;
}

MVKImage::~MVKImage() {
	if (_deviceMemory) { _deviceMemory->removeImage(this); }
	resetMTLTexture();
    resetIOSurface();
}


#pragma mark -
#pragma mark MVKImageView

void MVKImageView::populateMTLRenderPassAttachmentDescriptor(MTLRenderPassAttachmentDescriptor* mtlAttDesc) {
    mtlAttDesc.texture = getMTLTexture();           // Use image view, necessary if image view format differs from image format
    mtlAttDesc.level = _useMTLTextureView ? 0 : _subresourceRange.baseMipLevel;
    if (mtlAttDesc.texture.textureType == MTLTextureType3D) {
        mtlAttDesc.slice = 0;
        mtlAttDesc.depthPlane = _useMTLTextureView ? 0 : _subresourceRange.baseArrayLayer;
    } else {
        mtlAttDesc.slice = _useMTLTextureView ? 0 : _subresourceRange.baseArrayLayer;
        mtlAttDesc.depthPlane = 0;
    }
}

void MVKImageView::populateMTLRenderPassAttachmentDescriptorResolve(MTLRenderPassAttachmentDescriptor* mtlAttDesc) {
    mtlAttDesc.resolveTexture = getMTLTexture();    // Use image view, necessary if image view format differs from image format
    mtlAttDesc.resolveLevel = _useMTLTextureView ? 0 : _subresourceRange.baseMipLevel;
    if (mtlAttDesc.resolveTexture.textureType == MTLTextureType3D) {
        mtlAttDesc.resolveSlice = 0;
        mtlAttDesc.resolveDepthPlane = _useMTLTextureView ? 0 : _subresourceRange.baseArrayLayer;
    } else {
        mtlAttDesc.resolveSlice = _useMTLTextureView ? 0 : _subresourceRange.baseArrayLayer;
        mtlAttDesc.resolveDepthPlane = 0;
    }
}


#pragma mark Metal

id<MTLTexture> MVKImageView::getMTLTexture() {
	// If we can use a Metal texture view, lazily create it, otherwise use the image texture directly.
	if (_useMTLTextureView) {
		if ( !_mtlTexture && _mtlPixelFormat ) {

			// Lock and check again in case another thread created the texture view
			lock_guard<mutex> lock(_lock);
			if (_mtlTexture) { return _mtlTexture; }

			_mtlTexture = newMTLTexture(); // retained
		}
		return _mtlTexture;
	} else {
		return _image->getMTLTexture();
	}
}

// Creates and returns a retained Metal texture as an
// overlay on the Metal texture of the underlying image.
id<MTLTexture> MVKImageView::newMTLTexture() {
    MTLTextureType mtlTextureType = _mtlTextureType;
    // Fake support for 2D views of 3D textures.
    if (_image->getImageType() == VK_IMAGE_TYPE_3D &&
        (mtlTextureType == MTLTextureType2D || mtlTextureType == MTLTextureType2DArray))
        mtlTextureType = MTLTextureType3D;
    return [_image->getMTLTexture() newTextureViewWithPixelFormat: _mtlPixelFormat
                                                      textureType: mtlTextureType
                                                           levels: NSMakeRange(_subresourceRange.baseMipLevel, _subresourceRange.levelCount)
                                                           slices: NSMakeRange(_subresourceRange.baseArrayLayer, _subresourceRange.layerCount)];	// retained
}


#pragma mark Construction

// device and _image may be nil when a temporary instance
// is constructed to validate image view capabilities
MVKImageView::MVKImageView(MVKDevice* device,
						   const VkImageViewCreateInfo* pCreateInfo,
						   const MVKConfiguration* pAltMVKConfig) : MVKRefCountedDeviceObject(device) {
	_image = (MVKImage*)pCreateInfo->image;
	_usage = _image ? _image->_usage : 0;

	auto* next = (VkStructureType*)pCreateInfo->pNext;
	while (next) {
		switch (*next) {
		case VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO: {
			auto* pViewUsageInfo = (VkImageViewUsageCreateInfo*)next;
			if (!(pViewUsageInfo->usage & ~_usage))
				_usage = pViewUsageInfo->usage;
			next = (VkStructureType*)pViewUsageInfo->pNext;
			break;
		}
		default:
			next = (VkStructureType*)((VkImageViewCreateInfo*)next)->pNext;
			break;
		}
	}

	validateImageViewConfig(pCreateInfo);

	// Remember the subresource range, and determine the actual number of mip levels and texture slices
    _subresourceRange = pCreateInfo->subresourceRange;
	if (_subresourceRange.levelCount == VK_REMAINING_MIP_LEVELS) {
		_subresourceRange.levelCount = _image ? (_image->getMipLevelCount() - _subresourceRange.baseMipLevel) : 1;
	}
	if (_subresourceRange.layerCount == VK_REMAINING_ARRAY_LAYERS) {
		_subresourceRange.layerCount = _image ? (_image->getLayerCount() - _subresourceRange.baseArrayLayer) : 1;
	}

	bool useShaderSwizzle;
	bool isMultisample = _image ? _image->getSampleCount() != VK_SAMPLE_COUNT_1_BIT : false;
	_mtlTexture = nil;
    _mtlPixelFormat = getSwizzledMTLPixelFormat(pCreateInfo->format, pCreateInfo->components, useShaderSwizzle,
												(_device ? _device->_pMVKConfig : pAltMVKConfig));
	_packedSwizzle = useShaderSwizzle ? mvkPackSwizzle(pCreateInfo->components) : 0;
	_mtlTextureType = mvkMTLTextureTypeFromVkImageViewType(pCreateInfo->viewType, isMultisample);

	initMTLTextureViewSupport();
}

// Validate whether the image view configuration can be supported
void MVKImageView::validateImageViewConfig(const VkImageViewCreateInfo* pCreateInfo) {

	// No image if we are just validating view config
	MVKImage* image = (MVKImage*)pCreateInfo->image;
	if ( !image ) { return; }

	VkImageType imgType = image->getImageType();
	VkImageViewType viewType = pCreateInfo->viewType;

	// VK_KHR_maintenance1 supports taking 2D image views of 3D slices. No dice in Metal.
	if ((viewType == VK_IMAGE_VIEW_TYPE_2D || viewType == VK_IMAGE_VIEW_TYPE_2D_ARRAY) && (imgType == VK_IMAGE_TYPE_3D)) {
		if (pCreateInfo->subresourceRange.layerCount != image->_extent.depth) {
			mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImageView(): Metal does not fully support views on a subset of a 3D texture.");
		}
		if (!mvkAreFlagsEnabled(_usage, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) {
			setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImageView(): 2D views on 3D images are only supported for color attachments."));
		} else if (mvkIsAnyFlagEnabled(_usage, ~VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) {
			mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateImageView(): 2D views on 3D images are only supported for color attachments.");
		}
	}
}

// Returns a MTLPixelFormat, based on the MTLPixelFormat converted from the VkFormat, but possibly
// modified by the swizzles defined in the VkComponentMapping of the VkImageViewCreateInfo.
// Metal does not support general per-texture swizzles, so if the swizzle is not an identity swizzle, this
// function attempts to find an alternate MTLPixelFormat that coincidentally matches the swizzled format.
// If a replacement MTLFormat was found, it is returned and useShaderSwizzle is set to false.
// If a replacement MTLFormat could not be found, the original MTLPixelFormat is returned, and the
// useShaderSwizzle is set to true, indicating that shader swizzling should be used for this image view.
// The config is used to test whether full shader swizzle support is available, and to report an error if not.
MTLPixelFormat MVKImageView::getSwizzledMTLPixelFormat(VkFormat format,
													   VkComponentMapping components,
													   bool& useShaderSwizzle,
													   const MVKConfiguration* pMVKConfig) {

	// Attempt to find a valid format transformation swizzle first.
	MTLPixelFormat mtlPF = getMTLPixelFormatFromVkFormat(format);
	useShaderSwizzle = false;

	#define SWIZZLE_MATCHES(R, G, B, A)    mvkVkComponentMappingsMatch(components, {VK_COMPONENT_SWIZZLE_ ##R, VK_COMPONENT_SWIZZLE_ ##G, VK_COMPONENT_SWIZZLE_ ##B, VK_COMPONENT_SWIZZLE_ ##A} )
	#define VK_COMPONENT_SWIZZLE_ANY       VK_COMPONENT_SWIZZLE_MAX_ENUM

	switch (mtlPF) {
		case MTLPixelFormatR8Unorm:
			if (SWIZZLE_MATCHES(ZERO, ANY, ANY, R)) {
				return MTLPixelFormatA8Unorm;
			}
			break;

		case MTLPixelFormatA8Unorm:
			if (SWIZZLE_MATCHES(A, ANY, ANY, ZERO)) {
				return MTLPixelFormatR8Unorm;
			}
			break;

		case MTLPixelFormatRGBA8Unorm:
			if (SWIZZLE_MATCHES(B, G, R, A)) {
				return MTLPixelFormatBGRA8Unorm;
			}
			break;

		case MTLPixelFormatRGBA8Unorm_sRGB:
			if (SWIZZLE_MATCHES(B, G, R, A)) {
				return MTLPixelFormatBGRA8Unorm_sRGB;
			}
			break;

		case MTLPixelFormatBGRA8Unorm:
			if (SWIZZLE_MATCHES(B, G, R, A)) {
				return MTLPixelFormatRGBA8Unorm;
			}
			break;

		case MTLPixelFormatBGRA8Unorm_sRGB:
			if (SWIZZLE_MATCHES(B, G, R, A)) {
				return MTLPixelFormatRGBA8Unorm_sRGB;
			}
			break;

		case MTLPixelFormatDepth32Float_Stencil8:
			// If aspect mask looking only for stencil then change to stencil-only format even if shader swizzling is needed
			if (_subresourceRange.aspectMask == VK_IMAGE_ASPECT_STENCIL_BIT) {
				mtlPF = MTLPixelFormatX32_Stencil8;
				if (SWIZZLE_MATCHES(R, ANY, ANY, ANY)) {
					return mtlPF;
				}
			}
			break;

#if MVK_MACOS
		case MTLPixelFormatDepth24Unorm_Stencil8:
			// If aspect mask looking only for stencil then change to stencil-only format even if shader swizzling is needed
			if (_subresourceRange.aspectMask == VK_IMAGE_ASPECT_STENCIL_BIT) {
				mtlPF = MTLPixelFormatX24_Stencil8;
				if (SWIZZLE_MATCHES(R, ANY, ANY, ANY)) {
					return mtlPF;
				}
			}
			break;
#endif

		default:
			break;
	}

	// No format transformation swizzles were found, so unless we have an identity swizzle, we'll need to use shader swizzling.
	if ( !SWIZZLE_MATCHES(R, G, B, A)) {
		useShaderSwizzle = true;

		if ( !pMVKConfig->fullImageViewSwizzle ) {
			const char* vkCmd = _image ? "vkCreateImageView(VkImageViewCreateInfo" : "vkGetPhysicalDeviceImageFormatProperties2KHR(VkPhysicalDeviceImageViewSupportEXTX";
			const char* errMsg = ("The value of %s::components) (%s, %s, %s, %s), when applied to a VkImageView, requires full component swizzling to be enabled both at the"
								  " time when the VkImageView is created and at the time any pipeline that uses that VkImageView is compiled. Full component swizzling can"
								  " be enabled via the MVKConfiguration::fullImageViewSwizzle config parameter or MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE environment variable.");
			setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, errMsg, vkCmd,
														  mvkVkComponentSwizzleName(components.r), mvkVkComponentSwizzleName(components.g),
														  mvkVkComponentSwizzleName(components.b), mvkVkComponentSwizzleName(components.a)));
		}
	}

	return mtlPF;
}

// Determine whether this image view should use a Metal texture view,
// and set the _useMTLTextureView variable appropriately.
void MVKImageView::initMTLTextureViewSupport() {

	// If no image we're just validating image iview config
	if ( !_image ) {
		_useMTLTextureView = false;
		return;
	}

	_useMTLTextureView = _image->_canSupportMTLTextureView;

	bool is3D = _image->_mtlTextureType == MTLTextureType3D;
	// If the view is identical to underlying image, don't bother using a Metal view
	if (_mtlPixelFormat == _image->_mtlPixelFormat &&
		(_mtlTextureType == _image->_mtlTextureType ||
		 ((_mtlTextureType == MTLTextureType2D || _mtlTextureType == MTLTextureType2DArray) && is3D)) &&
		_subresourceRange.levelCount == _image->_mipLevels &&
		_subresourceRange.layerCount == (is3D ? _image->_extent.depth : _image->_arrayLayers)) {
		_useMTLTextureView = false;
	}
	// Never use views for subsets of 3D textures. Metal doesn't support them yet.
	if (is3D && _subresourceRange.layerCount != _image->_extent.depth) {
		_useMTLTextureView = false;
	}
}

MVKImageView::~MVKImageView() {
	[_mtlTexture release];
}


#pragma mark -
#pragma mark MVKSampler

// Returns an autoreleased Metal sampler descriptor constructed from the properties of this image.
MTLSamplerDescriptor* MVKSampler::getMTLSamplerDescriptor(const VkSamplerCreateInfo* pCreateInfo) {

	MTLSamplerDescriptor* mtlSampDesc = [[MTLSamplerDescriptor alloc] init];
	mtlSampDesc.sAddressMode = mvkMTLSamplerAddressModeFromVkSamplerAddressMode(pCreateInfo->addressModeU);
	mtlSampDesc.tAddressMode = mvkMTLSamplerAddressModeFromVkSamplerAddressMode(pCreateInfo->addressModeV);
    mtlSampDesc.rAddressMode = mvkMTLSamplerAddressModeFromVkSamplerAddressMode(pCreateInfo->addressModeW);
	mtlSampDesc.minFilter = mvkMTLSamplerMinMagFilterFromVkFilter(pCreateInfo->minFilter);
	mtlSampDesc.magFilter = mvkMTLSamplerMinMagFilterFromVkFilter(pCreateInfo->magFilter);
    mtlSampDesc.mipFilter = (pCreateInfo->unnormalizedCoordinates
                             ? MTLSamplerMipFilterNotMipmapped
                             : mvkMTLSamplerMipFilterFromVkSamplerMipmapMode(pCreateInfo->mipmapMode));
	mtlSampDesc.lodMinClamp = pCreateInfo->minLod;
	mtlSampDesc.lodMaxClamp = pCreateInfo->maxLod;
	mtlSampDesc.maxAnisotropy = (pCreateInfo->anisotropyEnable
								 ? mvkClamp(pCreateInfo->maxAnisotropy, 1.0f, _device->_pProperties->limits.maxSamplerAnisotropy)
								 : 1);
	mtlSampDesc.normalizedCoordinates = !pCreateInfo->unnormalizedCoordinates;

	if (pCreateInfo->compareEnable) {
		if (_device->_pMetalFeatures->depthSampleCompare) {
			mtlSampDesc.compareFunctionMVK = mvkMTLCompareFunctionFromVkCompareOp(pCreateInfo->compareOp);
		} else {
			setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateSampler(): Depth texture samplers do not support the comparison of the pixel value against a reference value."));
		}
	}

#if MVK_MACOS
	mtlSampDesc.borderColorMVK = mvkMTLSamplerBorderColorFromVkBorderColor(pCreateInfo->borderColor);
	if (_device->getPhysicalDevice()->getMetalFeatures()->samplerClampToBorder) {
		if (pCreateInfo->addressModeU == VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER) {
			mtlSampDesc.sAddressMode = MTLSamplerAddressModeClampToBorderColor;
		}
		if (pCreateInfo->addressModeV == VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER) {
			mtlSampDesc.tAddressMode = MTLSamplerAddressModeClampToBorderColor;
		}
		if (pCreateInfo->addressModeW == VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER) {
			mtlSampDesc.rAddressMode = MTLSamplerAddressModeClampToBorderColor;
		}
	}
#endif
	return [mtlSampDesc autorelease];
}

// Constructs an instance on the specified image.
MVKSampler::MVKSampler(MVKDevice* device, const VkSamplerCreateInfo* pCreateInfo) : MVKRefCountedDeviceObject(device) {
    _mtlSamplerState = [getMTLDevice() newSamplerStateWithDescriptor: getMTLSamplerDescriptor(pCreateInfo)];
}

MVKSampler::~MVKSampler() {
	[_mtlSamplerState release];
}


#pragma mark -
#pragma mark MVKSwapchainImage

bool MVKSwapchainImageAvailability_t::operator< (const MVKSwapchainImageAvailability_t& rhs) const {
	if (  isAvailable && !rhs.isAvailable) { return true; }
	if ( !isAvailable &&  rhs.isAvailable) { return false; }

	if (waitCount < rhs.waitCount) { return true; }
	if (waitCount > rhs.waitCount) { return false; }

	return acquisitionID < rhs.acquisitionID;
}

// Makes this image available for acquisition by the app.
// If any semaphores are waiting to be signaled when this image becomes available, the
// earliest semaphore is signaled, and this image remains unavailable for other uses.
void MVKSwapchainImage::makeAvailable() {
	lock_guard<mutex> lock(_availabilityLock);

	// Mark when this event happened, relative to that of other images
	_availability.acquisitionID = _swapchain->getNextAcquisitionID();

	// Mark this image as available if no semaphores or fences are waiting to be signaled.
	_availability.isAvailable = _availabilitySignalers.empty();

	MVKSwapchainSignaler signaler;
	if (_availability.isAvailable) {
		// If this image is now available, signal the semaphore and fence that were associated
		// with the last time this image was acquired while available. This is a workaround for
		// when an app uses a single semaphore or fence for more than one swapchain image.
		// Becuase the semaphore or fence will be signaled by more than one image, it will
		// get out of sync, and the final use of the image would not be signaled as a result.

		signaler = _preSignaled;
	} else {
		// If this image is not yet available, extract and signal the first semaphore and fence.

		signaler = _availabilitySignalers.front();
		_availabilitySignalers.erase( _availabilitySignalers.begin() );
	}

	// Signal the semaphore and fence, and let them know they are no longer being tracked.
	signal(signaler);
	unmarkAsTracked(signaler);

//	MVKLogDebug("Signaling%s swapchain image %p semaphore %p from present, with %lu remaining semaphores.", (_availability.isAvailable ? " pre-signaled" : ""), this, signaler.first, _availabilitySignalers.size());
}

void MVKSwapchainImage::signalWhenAvailable(MVKSemaphore* semaphore, MVKFence* fence) {
	lock_guard<mutex> lock(_availabilityLock);
	auto signaler = make_pair(semaphore, fence);
	if (_availability.isAvailable) {
		_availability.isAvailable = false;
		signal(signaler);
		_preSignaled = signaler;
	} else {
		_availabilitySignalers.push_back(signaler);
	}
	markAsTracked(signaler);

//	MVKLogDebug("%s swapchain image %p semaphore %p in acquire with %lu other semaphores.", (_availability.isAvailable ? "Signaling" : "Tracking"), this, semaphore, _availabilitySignalers.size());
}

// Signal either or both of the semaphore and fence in the specified tracker pair.
void MVKSwapchainImage::signal(MVKSwapchainSignaler& signaler) {
	if (signaler.first) { signaler.first->signal(); }
	if (signaler.second) { signaler.second->signal(); }
}

// Tell the semaphore and fence that they are being tracked for future signaling.
void MVKSwapchainImage::markAsTracked(MVKSwapchainSignaler& signaler) {
	if (signaler.first) { signaler.first->retain(); }
	if (signaler.second) { signaler.second->retain(); }
}

// Tell the semaphore and fence that they are no longer being tracked for future signaling.
void MVKSwapchainImage::unmarkAsTracked(MVKSwapchainSignaler& signaler) {
	if (signaler.first) { signaler.first->release(); }
	if (signaler.second) { signaler.second->release(); }
}

const MVKSwapchainImageAvailability* MVKSwapchainImage::getAvailability() {
	lock_guard<mutex> lock(_availabilityLock);
	_availability.waitCount = (uint32_t)_availabilitySignalers.size();
	return &_availability;
}


#pragma mark Metal

// Creates and returns a retained Metal texture suitable for use in this instance.
// This implementation retrieves a MTLTexture from the CAMetalDrawable.
id<MTLTexture> MVKSwapchainImage::newMTLTexture() {
	return [[getCAMetalDrawable() texture] retain];
}

id<CAMetalDrawable> MVKSwapchainImage::getCAMetalDrawable() {
	if ( !_mtlDrawable ) {
		@autoreleasepool {		// Allow auto-released drawable object to be reclaimed before end of loop
			_mtlDrawable = [_swapchain->getNextCAMetalDrawable() retain];	// retained
		}
		MVKAssert(_mtlDrawable, "Could not aquire an available CAMetalDrawable from the CAMetalLayer in MVKSwapchain image: %p.", this);
	}
	return _mtlDrawable;
}

void MVKSwapchainImage::presentCAMetalDrawable(id<MTLCommandBuffer> mtlCmdBuff) {
//	MVKLogDebug("Presenting swapchain image %p from present.", this);

    id<CAMetalDrawable> mtlDrawable = getCAMetalDrawable();
    _swapchain->willPresentSurface(getMTLTexture(), mtlCmdBuff);

    // If using a command buffer, present the drawable through it,
    // and make myself available only once the command buffer has completed.
    // Otherwise, immediately present the drawable and make myself available.
    if (mtlCmdBuff) {
        [mtlCmdBuff presentDrawable: mtlDrawable];
        resetMetalSurface();
        [mtlCmdBuff addCompletedHandler: ^(id<MTLCommandBuffer> mcb) { makeAvailable(); }];
    } else {
        [mtlDrawable present];
        resetMetalSurface();
        makeAvailable();
    }
}

// Removes and releases the Metal drawable object, so that it can be lazily created by getCAMetalDrawable().
void MVKSwapchainImage::resetCAMetalDrawable() {
	[_mtlDrawable release];
	_mtlDrawable = nil;
}

// Resets the MTLTexture and CAMetalDrawable underlying this image.
void MVKSwapchainImage::resetMetalSurface() {
    resetMTLTexture();			// Release texture first so drawable will be last to release it
    resetCAMetalDrawable();
}


#pragma mark Construction

MVKSwapchainImage::MVKSwapchainImage(MVKDevice* device,
									 const VkImageCreateInfo* pCreateInfo,
									 MVKSwapchain* swapchain) : MVKImage(device, pCreateInfo) {
	_swapchain = swapchain;
	_swapchainIndex = _swapchain->getImageCount();
	_availability.acquisitionID = _swapchain->getNextAcquisitionID();
	_availability.isAvailable = true;
	_preSignaled = make_pair(nullptr, nullptr);
	_mtlDrawable = nil;
    _canSupportMTLTextureView = false;		// Override...swapchains never support Metal image view.
}

MVKSwapchainImage::~MVKSwapchainImage() {
	resetCAMetalDrawable();
}


