#import "SCISymbol.h"
#import "../UI/SCIIcon.h"

@interface SCISymbol ()

@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite, nullable) NSString *igName;
@property (nonatomic, copy, readwrite) UIColor *color;
@property (nonatomic, readwrite) CGFloat size;
@property (nonatomic, readwrite) UIImageSymbolWeight weight;

@end

@implementation SCISymbol

- (instancetype)init {
	self = [super init];
	if (self) {
		self.name = @"";
		self.color = [UIColor labelColor];
		self.weight = UIImageSymbolWeightRegular;
		self.size = 15.0;
	}
	return self;
}

- (UIImage *)image {
	CGFloat pointSize = self.size > 0 ? self.size + 6.0 : 0.0;
	if (self.igName.length) {
		UIImage *explicitFB = [SCIIcon fbImageNamed:self.igName pointSize:pointSize];
		if (explicitFB) return explicitFB;
	}
	UIImage *resolved = [SCIIcon imageNamed:self.name pointSize:pointSize weight:self.weight];
	if (resolved) return resolved;
	return self.igName.length ? [SCIIcon imageNamed:self.igName pointSize:pointSize weight:self.weight] : nil;
}

// MARK: - Factories

+ (instancetype)symbolWithName:(NSString *)name {
	SCISymbol *s = [self new];
	s.name = name ?: @"";
	return s;
}

+ (instancetype)symbolWithName:(NSString *)name color:(UIColor *)color {
	SCISymbol *s = [self new];
	s.name = name ?: @"";
	s.color = color ?: UIColor.labelColor;
	return s;
}

+ (instancetype)symbolWithName:(NSString *)name color:(UIColor *)color size:(CGFloat)size {
	SCISymbol *s = [self new];
	s.name = name ?: @"";
	s.color = color ?: UIColor.labelColor;
	s.size = size;
	return s;
}

+ (instancetype)symbolWithName:(NSString *)name color:(UIColor *)color size:(CGFloat)size weight:(UIImageSymbolWeight)weight {
	SCISymbol *s = [self new];
	s.name = name ?: @"";
	s.color = color ?: UIColor.labelColor;
	s.size = size;
	s.weight = weight;
	return s;
}

+ (instancetype)symbolWithIGName:(NSString *)igName fallback:(NSString *)name {
	SCISymbol *s = [self new];
	s.igName = igName ?: @"";
	s.name = name ?: @"";
	return s;
}

+ (instancetype)symbolWithIGName:(NSString *)igName fallback:(NSString *)name color:(UIColor *)color {
	SCISymbol *s = [self new];
	s.igName = igName ?: @"";
	s.name = name ?: @"";
	s.color = color ?: UIColor.labelColor;
	return s;
}

+ (instancetype)symbolWithIGName:(NSString *)igName fallback:(NSString *)name color:(UIColor *)color size:(CGFloat)size {
	SCISymbol *s = [self new];
	s.igName = igName ?: @"";
	s.name = name ?: @"";
	s.color = color ?: UIColor.labelColor;
	s.size = size;
	return s;
}

@end
