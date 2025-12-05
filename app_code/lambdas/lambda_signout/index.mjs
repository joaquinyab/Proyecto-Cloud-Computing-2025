export const handler = async () => {
  return { statusCode: 302, headers: { Location: process.env.LOGIN_URL }, body: '' };
};
