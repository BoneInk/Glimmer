// IImageLayer.getVideoTexture(): the image's video texture, playing and looping from the start;
// null for a layer without one.
(function () {
    var video = thisScene.getLayer('background').getVideoTexture();
    if (video === null || video !== thisScene.getLayer('background').getVideoTexture()) return 'not one object';
    if (thisScene.getLayer('plain').getVideoTexture() !== null) return 'a picture has a video';
    if (video.duration !== 2 || !video.isPlaying() || !video.loop || video.rate !== 1) return 'not playing from the start';
    video.pause();
    if (video.isPlaying()) return 'pause';
    video.setCurrentTime(1.5);
    if (video.getCurrentTime() !== 1.5) return 'seek';
    video.stop();
    if (video.getCurrentTime() !== 0 || video.isPlaying()) return 'stop';
    video.play();
    return video.isPlaying() ? 'ok' : 'play';
})()
