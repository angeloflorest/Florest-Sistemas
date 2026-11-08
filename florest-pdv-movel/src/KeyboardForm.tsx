import React, { createContext, forwardRef, useContext, useEffect, useRef } from 'react';
import { Dimensions, Keyboard, ScrollView, TextInput, type ScrollViewProps, type TextInputProps } from 'react-native';
const FocusContext = createContext<(field: TextInput) => void>(() => {});
export function KeyboardScroll(props: ScrollViewProps) {
  const scroll = useRef<ScrollView>(null), focused = useRef<TextInput | null>(null);
  const offset = useRef(0), top = useRef(Dimensions.get('window').height);
  const reveal = () => focused.current?.measureInWindow((_x, y, _w, h) => {
    const extra = y + h + 20 - top.current;
    if (extra > 0) scroll.current?.scrollTo({ y: Math.max(0, offset.current + extra), animated: true });
  });
  useEffect(() => {
    const show = Keyboard.addListener('keyboardDidShow', event => { top.current = event.endCoordinates.screenY; requestAnimationFrame(reveal); });
    const hide = Keyboard.addListener('keyboardDidHide', () => { top.current = Dimensions.get('window').height; });
    return () => { show.remove(); hide.remove(); };
  }, []);
  return <FocusContext.Provider value={field => { focused.current = field; requestAnimationFrame(() => requestAnimationFrame(reveal)); }}>
    <ScrollView {...props} ref={scroll} keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag" automaticallyAdjustKeyboardInsets={false} scrollEventThrottle={16} onScroll={event => { offset.current = event.nativeEvent.contentOffset.y; props.onScroll?.(event); }}/>
  </FocusContext.Provider>;
}
export const KeyboardInput = forwardRef<TextInput, TextInputProps>((props, ref) => {
  const field = useRef<TextInput | null>(null), reveal = useContext(FocusContext);
  return <TextInput {...props} ref={value => {
    field.current = value;
    if (typeof ref === 'function') ref(value); else if (ref) ref.current = value;
  }} onFocus={event => { if (field.current) reveal(field.current); props.onFocus?.(event); }}/>;
});
