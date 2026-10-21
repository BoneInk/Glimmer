import * as WEMath from 'WEMath';
import { angleVector2 } from 'WEVector';
export let speed=1, range=70;
export function configure(properties) {
  if(properties.motionspeed!==undefined) speed=properties.motionspeed;
  if(properties.motionrange!==undefined) range=properties.motionrange;
}
export function origin(time) {
  const direction=angleVector2(time*speed*WEMath.rad2deg);
  return new Vec3(480+range*direction.y,300,0);
}
export function angle(time) {
  return new Vec3(0,0,WEMath.mix(15,375,(time*speed/8)%1));
}
